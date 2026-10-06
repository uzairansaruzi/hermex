import XCTest
import Observation
@testable import HermesMobile

/// A Hermes session's model, effort and Profile chips and its `/reasoning` and `/personality`
/// commands in the main chat (#1015, #1016), over #901's
/// socket-level host. `model.options` rows follow hermes-agent's `inventory.py` at the
/// `HERMES_AGENT_TESTED_SHA` pin.
@MainActor final class HermesChatSettingsTests: XCTestCase {
    // MARK: Catalog

    /// The picker lists authenticated providers' available models; capabilities key by model.
    func testCatalogSkipsUnauthenticatedProvidersAndUnavailableModels() {
        let catalog = HermesModelCatalog(Self.catalog)
        XCTAssertEqual(catalog.groups.map(\.id), ["anthropic", "nous"])
        XCTAssertEqual(catalog.groups.map { $0.models.map(\.id) }, [["claude-sonnet", "claude-opus"], ["hermes-4-70b"]],
                       "openrouter has no credential; hermes-4-405b is paid on a free tier")
        XCTAssertEqual(catalog.active, ModelCatalogOption(id: "claude-sonnet", displayName: "claude-sonnet",
                                                          providerID: "anthropic"))
        let opus = ModelCatalogOption(id: "claude-opus", displayName: "claude-opus", providerID: "anthropic")
        XCTAssertEqual(catalog.capabilities[opus.favoriteKey]?["fast"].flag, true)
    }

    // MARK: Model

    /// The chip shows the session's catalog for its Profile, read without `refresh`.
    func testTheModelChipListsTheSessionsCatalog() async {
        let chat = await openChat()
        XCTAssertEqual(chat.model.composerModelGroups.map(\.id), ["anthropic", "nous"])
        XCTAssertEqual(chat.model.selectedModelID, "claude-sonnet")
        XCTAssertEqual(chat.model.selectedModelProviderID, "anthropic")
        XCTAssertEqual(chat.model.selectedModelTitle, "claude-sonnet")
        XCTAssertEqual(chat.writes("model.options"), [["session_id": .string("runtime"), "profile": .string("work")]])
    }

    /// A pick sends exactly one session-scoped `config.set`, then reads the live model again.
    func testAPickSendsOneSessionScopedConfigSet() async {
        let chat = await openChat()
        chat.host.always("config.set", .init(result: Self.modelReply()))
        chat.host.always("model.options", .init(result: Self.catalog(active: "claude-opus")))

        let picked = await chat.model.selectComposerModel(Self.opus)
        XCTAssertTrue(picked)
        XCTAssertEqual(chat.writes("config.set"), [[
            "session_id": .string("runtime"), "profile": .string("work"), "scope": .string("session"),
            "key": .string("model"), "value": .string("claude-opus --provider anthropic --session"),
            "confirm_expensive_model": .bool(false)
        ]])
        XCTAssertEqual(chat.model.selectedModelID, "claude-opus")
        assertNeverWritesHostDefaults(chat)
    }

    /// The host's expensive-model message pauses the pick: Confirm resends it confirmed,
    /// Cancel sends nothing more.
    func testAnExpensiveModelAsksFirst() async throws {
        let chat = await openChat()
        let controls = try XCTUnwrap(chat.model.hermesSettings?.controls)
        chat.host.next("config.set", .init(result: Self.modelReply(confirm: true)))

        let picked = await chat.model.selectComposerModel(Self.opus)
        XCTAssertFalse(picked)
        XCTAssertEqual(controls.confirmation?.message, "Opus costs about 5x more.")
        controls.cancelConfirmation()
        XCTAssertEqual(chat.writes("config.set").count, 1, "cancel sends nothing")

        chat.host.next("config.set", .init(result: Self.modelReply(confirm: true)))
        _ = await chat.model.selectComposerModel(Self.opus)
        chat.host.next("config.set", .init(result: Self.modelReply()))
        await controls.confirm()
        XCTAssertEqual(chat.writes("config.set").map { $0["confirm_expensive_model"] },
                       [.bool(false), .bool(false), .bool(true)])
        XCTAssertNil(controls.errorMessage)
    }

    /// A pick the host holds for the running response shows as the chip's model, with a notice.
    func testADeferredPickShowsUntilTheResponseEnds() async {
        let chat = await openChat()
        chat.host.always("config.set", .init(result: Self.modelReply(deferred: true)))

        _ = await chat.model.selectComposerModel(Self.opus)
        XCTAssertEqual(chat.model.selectedModelID, "claude-opus")
        XCTAssertEqual(chat.model.composerConfigurationNotice, "Switches to claude-opus after this response.")

        chat.host.always("model.options", .init(result: Self.catalog(active: "claude-opus")))
        chat.receive(event(1, "session.info", ["running": .bool(false), "model": .string("claude-opus")]))
        await waitUntil("applied") { chat.model.composerConfigurationNotice == nil }
        XCTAssertEqual(chat.model.selectedModelID, "claude-opus")
    }

    /// `/model` resolves against the catalog and goes through the chip's pick; a name the
    /// host doesn't offer sends nothing.
    func testSlashModelUsesTheSamePick() async {
        let chat = await openChat()
        chat.host.always("config.set", .init(result: Self.modelReply()))

        let unknown = await chat.model.executeSlashCommand(Self.command("model"), args: "gpt-x")
        XCTAssertEqual(unknown, .unsupported(friendlyMessage: "This host doesn't offer a model named gpt-x."))
        XCTAssertEqual(chat.writes("config.set"), [])

        let switched = await chat.model.executeSlashCommand(Self.command("model"), args: "opus")
        XCTAssertEqual(switched, .executed(message: nil))
        XCTAssertEqual(chat.writes("config.set").map { $0["value"] },
                       [.string("claude-opus --provider anthropic --session")])
    }

    // MARK: Reasoning

    /// The effort menu offers the host's ladder from `capabilities`: without None for a model
    /// that can't turn reasoning off, and not at all for one that doesn't reason.
    func testTheEffortLadderFollowsTheModelsCapabilities() async throws {
        let chat = await openChat()
        let controls = try XCTUnwrap(chat.model.hermesSettings?.controls)
        XCTAssertTrue(chat.model.showsReasoningEffortControl)
        XCTAssertEqual(chat.model.composerSupportedReasoningEfforts, HermesModelCatalog.effortLevels)

        chat.host.always("model.options", .init(result: Self.catalog(active: "claude-opus")))
        await controls.reload()
        XCTAssertTrue(chat.model.showsReasoningEffortControl)
        XCTAssertEqual(chat.model.composerSupportedReasoningEfforts,
                       ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"])

        chat.host.always("model.options", .init(result: Self.catalog(active: "hermes-4-70b", provider: "nous")))
        await controls.reload()
        XCTAssertFalse(chat.model.showsReasoningEffortControl)
    }

    /// A pick in a new chat goes out once, session-scoped, on the session minted when it
    /// opened and before any prompt. Without a runtime, nothing is sent.
    func testAnEffortPickSendsOneSessionScopedConfigSet() async {
        let chat = await openChat()
        chat.host.always("config.set", .init(result: Self.effortReply("high")))

        let picked = await chat.model.selectReasoningEffort("high")
        XCTAssertTrue(picked)
        XCTAssertEqual(chat.writes("config.set"), [[
            "session_id": .string("runtime"), "profile": .string("work"), "scope": .string("session"),
            "key": .string("reasoning"), "value": .string("high")
        ]])
        XCTAssertEqual(chat.model.composerReasoningEffort, "high")
        let methods = chat.host.requests.compactMap { $0["method"].text }
        XCTAssertLessThan(methods.firstIndex(of: "session.create") ?? .max, methods.firstIndex(of: "config.set") ?? -1)
        XCTAssertFalse(methods.contains("prompt.submit"))
        let again = await chat.model.selectReasoningEffort("high")
        XCTAssertFalse(again, "the same level is not resent")

        chat.turn.settings.disconnect()
        let offline = await chat.model.selectReasoningEffort("low")
        XCTAssertFalse(offline)
        XCTAssertEqual(chat.writes("config.set").count, 1)
        assertNeverWritesHostDefaults(chat)
    }

    /// `session.info` names the level the host sent; the chip shows it only when it is lower.
    func testTheChipShowsTheLevelTheHostSent() async {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["reasoning_effort": .string("xhigh"),
                                               "reasoning_effort_wire": .string("high")]))
        await waitUntil("info") { chat.model.composerReasoningEffort == "xhigh" }
        XCTAssertEqual(chat.model.composerSentReasoningEffort, "high")

        chat.receive(event(2, "session.info", ["reasoning_effort": .string("high"),
                                               "reasoning_effort_wire": .string("high")]))
        await waitUntil("matching") { chat.model.composerReasoningEffort == "high" }
        XCTAssertNil(chat.model.composerSentReasoningEffort)

        chat.receive(event(3, "session.info", ["reasoning_effort": .string("ultra"),
                                               "reasoning_effort_wire": .string("")]))
        await waitUntil("unreported") { chat.model.composerReasoningEffort == "ultra" }
        XCTAssertNil(chat.model.composerSentReasoningEffort)

        // A new model's route may take the level whole; the old model's report goes with it.
        chat.receive(event(4, "session.info", ["reasoning_effort": .string("ultra"),
                                               "reasoning_effort_wire": .string("max")]))
        await waitUntil("lowered") { chat.model.composerSentReasoningEffort == "max" }
        chat.host.always("config.set", .init(result: Self.modelReply()))
        chat.host.always("model.options", .init(result: Self.catalog(active: "claude-opus")))
        _ = await chat.model.selectComposerModel(Self.opus)
        XCTAssertNil(chat.model.composerSentReasoningEffort)
    }

    /// `/reasoning <level>` takes the chip's path; a display word is refused and sends nothing.
    func testSlashReasoningSetsALevelAndRefusesDisplayWords() async {
        let chat = await openChat()
        chat.host.always("config.set", .init(result: Self.effortReply("max")))

        for word in ["show", "hide", "off"] {
            let refused = await chat.model.executeSlashCommand(Self.command("reasoning"), args: word)
            XCTAssertEqual(refused, .unsupported(friendlyMessage:
                "On a Hermes host, /reasoning \(word) changes display settings for every client, so Hermex doesn't send it."))
        }
        let usage = await chat.model.executeSlashCommand(Self.command("reasoning"), args: "")
        XCTAssertEqual(usage, .unsupported(friendlyMessage: "Usage: /reasoning none|minimal|low|medium|high|xhigh|max|ultra"))
        XCTAssertEqual(chat.writes("config.set"), [])

        let set = await chat.model.executeSlashCommand(Self.command("reasoning"), args: "MAX")
        XCTAssertEqual(set, .executed(message: nil))
        XCTAssertEqual(chat.writes("config.set").map { $0["value"] }, [.string("max")])
        XCTAssertEqual(chat.model.composerReasoningEffort, "max")
    }

    /// Like the effort menu, `/reasoning` waits for a running reply to finish.
    func testSlashReasoningWaitsForTheRunningReply() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        await waitUntil("running") { chat.model.activeStreamID != nil }

        let refused = await chat.model.executeSlashCommand(Self.command("reasoning"), args: "high")
        XCTAssertEqual(refused, .unsupported(friendlyMessage: "Wait for the current response to finish before changing reasoning."))
        XCTAssertEqual(chat.writes("config.set"), [])
    }

    // MARK: Personality

    /// Bare `/personality` lists the host's personalities from the one fixed completion.
    func testSlashPersonalityListsTheHostsPersonalities() async {
        let chat = await openChat()
        chat.host.always("complete.slash", .init(result: .object(["replace_from": .number(13), "items": .array([
            .object(["text": .string("none"), "display": .string("none"), "meta": .string("clear personality overlay"),
                     "kind": .string("command")]),
            .object(["text": .string("concise"), "display": .string("concise"), "meta": .string("Brief answers"),
                     "kind": .string("command")]),
            .object(["text": .string("pirate"), "display": .string("pirate"), "meta": .string(""), "kind": .string("command")])
        ])])))

        let listed = await chat.model.executeSlashCommand(Self.command("personality"), args: "")
        XCTAssertEqual(listed, .executed(message: "Available personalities:\n\n- **concise** - Brief answers\n- **pirate**\n\n"
                                         + "Use `/personality <name>` or `/personality none`."))
        XCTAssertEqual(chat.writes("complete.slash"), [["text": .string("/personality "), "session_id": .string("runtime")]])
    }

    /// A name asks first; Cancel sends nothing, and confirming sends one Profile-wide
    /// `config.set` for this session. The clear words send `none`.
    func testSlashPersonalityAsksThenSetsTheProfilesPersonality() async throws {
        let chat = await openChat()
        let settings = try XCTUnwrap(chat.model.hermesSettings)
        chat.host.always("config.set", .init(result: .object(["key": .string("personality"), "value": .string("pirate"),
                                                             "history_reset": .bool(false)])))

        let asked = await chat.model.executeSlashCommand(Self.command("personality"), args: "pirate")
        XCTAssertEqual(asked, .executed(message: nil))
        XCTAssertEqual(settings.pendingPersonality, "pirate")
        settings.cancelPersonality()
        XCTAssertNil(settings.pendingPersonality)
        XCTAssertEqual(chat.writes("config.set"), [], "cancel sends nothing")

        let set = await chat.model.confirmHermesPersonality("pirate")
        XCTAssertEqual(set, .executed(message: "Personality for **work** set to **pirate**."))
        XCTAssertEqual(chat.writes("config.set"), [[
            "session_id": .string("runtime"), "profile": .string("work"),
            "key": .string("personality"), "value": .string("pirate")
        ]])

        _ = await chat.model.executeSlashCommand(Self.command("personality"), args: "Clear")
        XCTAssertEqual(settings.pendingPersonality, "none")
        let cleared = await chat.model.confirmHermesPersonality("none")
        XCTAssertEqual(cleared, .executed(message: "Personality cleared for **work**."))
        XCTAssertEqual(chat.writes("config.set").last?["value"], .string("none"))
    }

    /// A personality the Profile lacks shows the host's refusal.
    func testARefusedPersonalityShowsTheHostsMessage() async {
        let chat = await openChat()
        chat.host.next("config.set", .init(error: 5001))

        let refused = await chat.model.confirmHermesPersonality("launch-only")
        XCTAssertEqual(refused, .unsupported(friendlyMessage: "refused"))
        XCTAssertEqual(chat.writes("config.set").count, 1)
    }

    // MARK: Profile

    /// The chip lists the host's Profiles, the onboarding one included, with the session's selected.
    func testTheProfileChipListsTheHostsProfiles() async {
        let chat = await openChat()
        await waitUntil("profiles") { !chat.model.composerProfileOptions.isEmpty }
        XCTAssertEqual(chat.model.composerProfileOptions.map(\.name), ["default", "work", "setup"])
        XCTAssertFalse(chat.model.composerIsSingleProfileMode)
        XCTAssertEqual(chat.model.selectedProfileTitle, "work")
        XCTAssertEqual(chat.model.selectedProfileName, "work", "the menu's checkmark")
        XCTAssertTrue(chat.model.isSelectedProfile(Self.profile("work")))
        XCTAssertFalse(chat.model.isSelectedProfile(Self.profile("default")))
    }

    /// Another Profile is a new chat on the same connection; a chat with nothing sent hands
    /// its draft over. The session's own Profile is never changed on the host.
    func testAnotherProfileStartsANewChatWithTheDraft() async throws {
        let chat = await openChat()
        let key = try XCTUnwrap(chat.model.hermesDraftKey)
        chat.drafts.setContent(ComposerDraftContent(text: "hello", quotes: []), for: key)

        let next = try XCTUnwrap(chat.model.newHermesSessionChat(profile: "default"))
        XCTAssertEqual(next.target, .new(profile: "default"))
        XCTAssertEqual(next.connection, Self.connection)
        await chat.model.handOffHermesDraft(to: next)
        let nextKey = next.target.draftKey(server: next.server, connectionID: Self.connection.id)
        let moved = await chat.drafts.draft(for: nextKey)
        XCTAssertEqual(moved?.text, "hello")
        let left = await chat.drafts.draft(for: key)
        XCTAssertNil(left)

        // A draft already waiting in the other Profile's new chat is never replaced.
        chat.drafts.setContent(ComposerDraftContent(text: "again", quotes: []), for: key)
        await chat.model.handOffHermesDraft(to: next)
        let kept = await chat.drafts.draft(for: nextKey)
        XCTAssertEqual(kept?.text, "hello")
        let stayed = await chat.drafts.draft(for: key)
        XCTAssertEqual(stayed?.text, "again")
        XCTAssertEqual(chat.turn.engine.target.profile, "work")
        assertNeverWritesHostDefaults(chat)
    }

    /// New Session's Profile: the pick saved for this server while the host lists it, else
    /// `current`. A stale pick is dropped; other servers keep theirs.
    func testTheRememberedProfileIsPerServerAndFallsBackToCurrent() {
        let defaults = UserDefaults.ephemeral()
        let hermes = URL(string: "https://hermes.example")!, other = URL(string: "https://other.example")!
        XCTAssertEqual(HermesProfilePreference.resolve(for: hermes, listed: ["default", "work"], current: "default",
                                                       in: defaults), "default", "nothing saved")

        HermesProfilePreference.save("work", for: hermes, in: defaults)
        HermesProfilePreference.save("research", for: other, in: defaults)
        XCTAssertEqual(HermesProfilePreference.resolve(for: hermes, listed: ["default", "work"], current: "default",
                                                       in: defaults), "work")
        XCTAssertEqual(HermesProfilePreference.resolve(for: hermes, listed: [], current: "default", in: defaults),
                       "default", "an unread roster proves nothing")
        XCTAssertEqual(defaults.string(forKey: HermesProfilePreference.key(for: hermes)), "work")

        XCTAssertEqual(HermesProfilePreference.resolve(for: hermes, listed: ["default"], current: "default",
                                                       in: defaults), "default", "the host deleted work")
        XCTAssertNil(defaults.string(forKey: HermesProfilePreference.key(for: hermes)))
        XCTAssertEqual(defaults.string(forKey: HermesProfilePreference.key(for: other)), "research")
    }

    // MARK: Fixture

    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")
    private static let opus = ModelCatalogOption(id: "claude-opus", displayName: "claude-opus", providerID: "anthropic")

    private static func command(_ name: String) -> SlashCommand { SlashCommandCatalog.command(named: name)! }

    private static func profile(_ name: String) -> ProfileSummary {
        ProfileSummary(name: name, path: nil, isDefault: nil, isActive: nil, gatewayRunning: nil, model: nil,
                       provider: nil, hasEnv: nil, skillCount: nil)
    }

    /// `model.options` as the pin answers it: an authenticated row with capabilities, an
    /// unauthenticated one, and a free-tier row whose paid model is unavailable.
    private static var catalog: BotJSON { catalog(active: "claude-sonnet") }

    private static func catalog(active: String, provider: String = "anthropic") -> BotJSON {
        .object(["model": .string(active), "provider": .string(provider), "providers": .array([
            .object(["slug": .string("anthropic"), "name": .string("Anthropic"), "is_current": .bool(true),
                     "is_user_defined": .bool(false), "models": .array([.string("claude-sonnet"), .string("claude-opus")]),
                     "total_models": .number(2), "authenticated": .bool(true),
                     "capabilities": .object([
                        "claude-sonnet": .object(["fast": .bool(false), "reasoning": .bool(true)]),
                        "claude-opus": .object(["fast": .bool(true), "reasoning": .bool(true),
                                                "can_disable_reasoning": .bool(false)])
                     ])]),
            .object(["slug": .string("openrouter"), "name": .string("OpenRouter"), "is_current": .bool(false),
                     "is_user_defined": .bool(false), "models": .array([.string("gpt-x")]), "total_models": .number(1),
                     "authenticated": .bool(false), "capabilities": .object([:])]),
            .object(["slug": .string("nous"), "name": .string("Nous Portal"), "is_current": .bool(false),
                     "is_user_defined": .bool(false), "models": .array([.string("hermes-4-405b"), .string("hermes-4-70b")]),
                     "total_models": .number(2), "authenticated": .bool(true), "free_tier": .bool(true),
                     "unavailable_models": .array([.string("hermes-4-405b")]),
                     "capabilities": .object(["hermes-4-70b": .object(["reasoning": .bool(false)])])])
        ])])
    }

    private static func modelReply(confirm: Bool = false, deferred: Bool = false) -> BotJSON {
        .object(["key": .string("model"), "value": .string("claude-opus"), "scope": .string("session"),
                 "confirm_required": .bool(confirm), "confirm_message": .string("Opus costs about 5x more."),
                 "deferred": .bool(deferred)])
    }

    private static func effortReply(_ value: String) -> BotJSON {
        .object(["key": .string("reasoning"), "value": .string(value)])
    }

    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost
        let client: BotClient
        let drafts: ChatDraftStore

        @MainActor func receive(_ frame: BotJSON) { client.onEvent?(frame) }

        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    /// A new chat in Profile `work`, attached on `runtime`, with its catalog read.
    private func openChat() async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.create", .init(result: .object([
            "session_id": .string("runtime"), "stored_session_id": .string("tip")
        ])))
        host.always("session.resume", .init(result: .object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
            "messages": .array([]), "info": .object(["profile_name": .string("work")])
        ])))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        host.always("model.options", .init(result: Self.catalog))
        host.always("profiles.list", .init(result: .object(["profiles": .array([
            .object(["name": .string("default")]), .object(["name": .string("work")]),
            .object(["name": .string("setup"), "role": .string("setup"), "previous_names": .array([])])
        ])])))
        let client = BotClient(http: host.connection(Self.connection))
        let engine = HermesConversation(server: URL(string: "https://hermes.example")!, connection: Self.connection,
                                        target: .new(profile: "work"), wire: client)
        let turn = HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true })
        let drafts = ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60))
        let model = ChatViewModel(
            session: SessionSummary(profile: "work"), server: URL(string: "https://hermes.example")!,
            streamingScrollCoalescingDelayNanoseconds: 0, draftStore: drafts, backend: .hermes(turn)
        )
        await model.loadMessages()
        XCTAssertEqual(engine.connectionState, .connected)
        await waitUntil("catalog") { turn.settings.controls.catalog.active != nil }
        return Chat(model: model, turn: turn, host: host, client: client, drafts: drafts)
    }

    /// No request moves the host's defaults: no `--global`, no `refresh`, no Profile switch.
    private func assertNeverWritesHostDefaults(_ chat: Chat, file: StaticString = #filePath, line: UInt = #line) {
        for request in chat.host.requests {
            let params = request["params"]
            XCTAssertNil(params["refresh"].flag, file: file, line: line)
            XCTAssertFalse(params["value"].text?.contains("--global") == true, file: file, line: line)
            XCTAssertNotEqual(params["scope"].text, "global", file: file, line: line)
        }
    }

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

    private func event(_ seq: Int, _ type: String, _ payload: [String: BotJSON] = [:]) -> BotJSON {
        .object(["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string(type),
                 "payload": .object(payload)])
    }
}
