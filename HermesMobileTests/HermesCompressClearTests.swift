import XCTest
import Observation
@testable import HermesMobile

/// `/compress`, `/compact` and `/clear` in a Hermes session (#1050), over #901's socket-level
/// host and scripted transcript pages. Compress is `session.compress` on the runtime
/// (`tui_gateway/methods_session.py`); the reply and page shapes are the ones
/// `scripts/local-hermes` answered at the `HERMES_AGENT_TESTED_SHA` pin, where an in-place
/// compaction soft-archives the middle turns (`active` 0) and re-inserts the rest under new ids.
@MainActor final class HermesCompressClearTests: XCTestCase {
    // MARK: Compress

    /// `/compress` names the session's runtime and Profile; `/compact` is the same call, and
    /// sends its focus.
    func testCompressSendsTheProfileAndAnyFocus() async {
        let chat = await openChat(threeTurns)
        chat.host.always("session.compress", .init(result: compressed(removed: 4)))
        chat.pages["tip"] = compactedTurns

        _ = await chat.model.runHermesSlashCommand("/compress")
        _ = await chat.model.runHermesSlashCommand("/compact  focus on the API ")

        XCTAssertEqual(chat.writes("session.compress"), [
            ["session_id": .string("runtime"), "profile": .string("default")],
            ["session_id": .string("runtime"), "profile": .string("default"), "focus_topic": .string("focus on the API")]
        ])
        XCTAssertEqual(chat.writes("slash.exec"), [], "never the host's own /compress")
    }

    /// Once the host compacts, the newest page replaces the transcript: the compacted turns, the
    /// compaction card after them, and the turns after it. One note says what was removed.
    func testACompactionRereadsTheNewestPageAndPostsTheNote() async throws {
        let chat = await openChat(threeTurns)
        chat.host.always("session.compress", .init(result: compressed(removed: 4)))
        chat.pages["tip"] = compactedTurns

        let result = await chat.model.runHermesSlashCommand("/compact the API")

        XCTAssertEqual(result, .executed(message: """
            Context compressed.

            Compressed: 6 → 4 messages
            Approx request size: ~900 → ~400 tokens
            Focus: the API
            """))
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [7, 8, 3, 4, 10, 11])
        XCTAssertEqual(chat.model.messages.filter(\.isCompacted).compactMap(\.rowID), [3, 4])
        XCTAssertEqual(chat.model.compressionReferenceCard?.referenceText, "The user asked for two answers.")
        XCTAssertFalse(chat.model.isCompressingSession)
    }

    /// A compaction that removed nothing, an aborted one, another compressor holding the lock,
    /// one still running on the compute host and a busy host (4009) each say why on the status
    /// line, keep the draft, and read nothing.
    func testWhatTheHostDidNotCompressShowsItsMessage() async {
        let chat = await openChat(threeTurns)
        let refusals: [(String, BotSocketHost.Reply, String)] = [
            ("aborted", .init(result: .object([
                "status": .string("aborted"), "removed": .number(0),
                "summary": .object(["headline": .string("Compression aborted: 6 messages preserved"),
                                    "note": .string("Summary generation failed; no messages were removed.")])
            ])), "Summary generation failed; no messages were removed."),
            ("nothing removed", .init(result: .object([
                "status": .string("compressed"), "removed": .number(0),
                "summary": .object(["headline": .string("No changes from compression: 6 messages"), "note": .null])
            ])), "No changes from compression: 6 messages"),
            ("lock held", .init(result: .object([
                "compressed": .bool(false), "lock_held": .bool(true),
                "message": .string("⏳ Compression already in progress for this session (holder: cli). Please wait for it to finish.")
            ])), "⏳ Compression already in progress for this session (holder: cli). Please wait for it to finish."),
            ("lock held, unworded", .init(result: .object(["compressed": .bool(false), "lock_held": .bool(true)])),
             "Already compressing; try again shortly."),
            ("pending", .init(result: .object([
                "status": .string("pending"), "turn_isolation": .bool(true),
                "message": .string("compression still running in the background; the transcript will refresh when it finishes")
            ])), "compression still running in the background; the transcript will refresh when it finishes"),
            ("busy", .init(error: 4009, message: "session busy — Hermes is still replying."), "Wait for the current reply to finish.")
        ]
        let reads = chat.pages.reads
        for (attempt, (name, reply, shown)) in refusals.enumerated() {
            chat.host.next("session.compress", reply)
            let result = await chat.model.runHermesSlashCommand("/compress")
            XCTAssertEqual(result, .notDelivered, name)
            XCTAssertEqual(chat.model.sendErrorMessage, shown, name)
            XCTAssertEqual(chat.writes("session.compress").count, attempt + 1, name)
        }
        XCTAssertEqual(chat.pages.reads, reads, "nothing was compacted, so nothing is read")
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 4, 5, 6])
    }

    /// While a reply streams, `/compress` asks to wait and sends nothing.
    func testCompressingDuringAReplyIsRefused() async {
        let chat = await openChat(threeTurns)
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Run it")
        chat.receive(event(1, "message.start"))

        let result = await chat.model.runHermesSlashCommand("/compress")

        XCTAssertEqual(result, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, "Wait for the current reply to finish.")
        XCTAssertEqual(chat.writes("session.compress"), [])
    }

    /// Leaving while the host summarizes, as backgrounding does, loses the answer. Nothing is
    /// sent again, and on return the chat reads the compacted history from the newest page
    /// instead of keeping the rows it held.
    func testACompactionWhoseAnswerWasLostIsReadOnReturn() async {
        let chat = await openChat(threeTurns)
        chat.host.withhold("session.compress")
        let sent = expectation(description: "session.compress went out")
        chat.host.expect(sent, onNext: "session.compress")

        let compressing = Task { await chat.model.runHermesSlashCommand("/compress") }
        await fulfillment(of: [sent], timeout: 5)
        chat.model.suspendStreamForNavigation()
        let result = await compressing.value
        XCTAssertEqual(result, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, "The server did not confirm the change.")
        chat.pages["tip"] = compactedTurns
        await chat.model.reconnectStreamIfNeeded()

        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [7, 8, 3, 4, 10, 11])
        XCTAssertEqual(chat.model.compressionReferenceCard?.referenceText, "The user asked for two answers.")
        XCTAssertEqual(chat.writes("session.compress").count, 1)
    }

    /// A compute host that answers `pending` finishes later and says so with
    /// `status.update {kind: "compacted"}`: then the chat reads the compacted history.
    func testAPendingCompactionIsReadWhenTheHostFinishes() async {
        let chat = await openChat(threeTurns)
        chat.host.next("session.compress", .init(result: .object([
            "status": .string("pending"), "turn_isolation": .bool(true),
            "message": .string("compression still running in the background; the transcript will refresh when it finishes")
        ])))
        let result = await chat.model.runHermesSlashCommand("/compress")
        XCTAssertEqual(result, .notDelivered)
        chat.pages["tip"] = compactedTurns

        chat.receive(event(1, "status.update", ["kind": .string("compacted"), "text": .string("✓ Context compression complete")]))

        await waitUntil("the compacted history") { chat.model.messages.compactMap(\.rowID) == [7, 8, 3, 4, 10, 11] }
        XCTAssertEqual(chat.model.compressionReferenceCard?.referenceText, "The user asked for two answers.")
    }

    // MARK: Stored key rotation

    /// A host on legacy compaction re-points the session to a new stored key, which its
    /// `session.info` reports. The chat reads the new key's page, keeps its root and draft key,
    /// and goes on sending on the same runtime.
    func testARotatedStoredKeyIsAdoptedAndTheRootKept() async {
        let chat = await openChat(threeTurns)
        let draftKey = chat.model.hermesDraftKey
        chat.host.always("session.compress", .init(result: compressed(removed: 4, storedKey: "tip-2"), before: [
            event(1, "session.info", ["stored_session_id": .string("tip-2"), "running": .bool(false)])
        ]))
        chat.pages["tip-2"] = compactedTurns

        _ = await chat.model.runHermesSlashCommand("/compress")

        XCTAssertEqual(chat.turn.engine.storedKey, "tip-2")
        XCTAssertEqual(chat.turn.engine.root, "tip")
        XCTAssertEqual(chat.model.hermesDraftKey, draftKey)
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [7, 8, 3, 4, 10, 11], "the new key's page")
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Keep going")
        XCTAssertEqual(chat.writes("prompt.submit").map { $0["session_id"] }, [.string("runtime")])
    }

    /// A bot's Bot Chat follows the new key too (#1145, reversing #1099's "never for a Bot
    /// Chat"), so `/compress` leaves it writable: later pages read the new key, while the
    /// canonical root, the bot's draft key and the next attach's title lookup stay as they were.
    func testABotChatFollowsItsRotatedStoredKeyAndKeepsSending() async {
        let chat = await openChat(threeTurns, target: .canonicalChat(profile: "default"))
        let draftKey = chat.model.hermesDraftKey
        XCTAssertEqual(draftKey, .bot(server: URL(string: "https://hermes.example")!, connectionID: Self.connection.id,
                                      profile: "default"))
        chat.host.always("session.compress", .init(result: compressed(removed: 4, storedKey: "tip-2"), before: [
            event(1, "session.info", ["stored_session_id": .string("tip-2"), "running": .bool(false)])
        ]))
        chat.pages["tip-2"] = compactedTurns

        _ = await chat.model.runHermesSlashCommand("/compress")

        XCTAssertEqual(chat.turn.engine.storedKey, "tip-2")
        XCTAssertEqual(chat.turn.engine.root, "root", "the canonical root the title lookup found")
        XCTAssertEqual(chat.model.hermesDraftKey, draftKey)
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [7, 8, 3, 4, 10, 11], "the new key's page")
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Keep going")
        XCTAssertEqual(chat.writes("prompt.submit").map { $0["session_id"] }, [.string("runtime")])
    }

    /// The host's own compaction mid-turn reports the new key the same way.
    func testAutoCompressionMidTurnAdoptsTheRotatedKey() async {
        let chat = await openChat(threeTurns)
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "session.info", ["stored_session_id": .string("tip-2"), "running": .bool(true)]))

        XCTAssertEqual(chat.turn.engine.storedKey, "tip-2")
        XCTAssertEqual(chat.turn.engine.root, "tip")
    }

    /// Pushes and run alerts name the session by its current stored key (#1177), so the open
    /// chat's replies stay quiet and its alert opens it after the key moves.
    func testPushPresenceAndTheRunAlertFollowTheRotatedKey() async {
        let chat = await openChat(threeTurns)
        let server = URL(string: "https://hermes.example")!
        XCTAssertEqual(chat.model.pushPresence, PushPresence.Viewer(server: server, sessionID: "tip"))

        chat.receive(event(1, "session.info", ["stored_session_id": .string("tip-2"), "running": .bool(false)]))

        XCTAssertEqual(chat.model.pushPresence, PushPresence.Viewer(server: server, sessionID: "tip-2"))
        XCTAssertEqual(chat.model.hermesSessionLink, HermesSessionDestination(server: server, profile: "default", key: "tip-2"))
    }

    // MARK: Clear

    /// `/clear` opens a new chat in this one's place, in its Profile, on the model its chip
    /// shows and in its working folder. The old chat keeps its session and history, and
    /// nothing is cleared on the host.
    func testClearOpensANewChatWithTheProfileModelAndFolder() async {
        let chat = await openChat(threeTurns, info: ["cwd": .string("/work/app")], catalog: .object([
            "model": .string("claude-opus"), "provider": .string("anthropic"), "providers": .array([
                .object(["slug": .string("anthropic"), "name": .string("Anthropic"), "authenticated": .bool(true),
                         "models": .array([.string("claude-sonnet"), .string("claude-opus")])])
            ])
        ]))
        await waitUntil("the model chip") { chat.turn.settings.selectedModel != nil }

        let result = await chat.model.runHermesSlashCommand("/clear")

        guard case .replacedHermesSession(let next)? = result else { return XCTFail("Expected a chat in this one's place") }
        XCTAssertEqual(next.target, .new(profile: "default", cwd: "/work/app",
                                         model: HermesCall.Model(id: "claude-opus", provider: "anthropic")))
        XCTAssertEqual(next.connection, Self.connection)
        XCTAssertEqual(chat.turn.engine.target, .session(profile: "default", key: "tip"))
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(chat.writes("slash.exec"), [], "never the host's own /clear")
        XCTAssertEqual(chat.writes("session.create"), [])
    }

    /// Before the chip's catalog answers, or when it fails, `/clear` keeps the model and
    /// provider the host reported for this chat instead of the Profile's default.
    func testClearKeepsTheReportedModelWithoutTheCatalog() async {
        let chat = await openChat(threeTurns, info: [
            "cwd": .string("/work/app"), "model": .string("claude-opus"), "provider": .string("anthropic")
        ])

        let result = await chat.model.runHermesSlashCommand("/clear")

        guard case .replacedHermesSession(let next)? = result else { return XCTFail("Expected a chat in this one's place") }
        XCTAssertEqual(next.target, .new(profile: "default", cwd: "/work/app",
                                         model: HermesCall.Model(id: "claude-opus", provider: "anthropic")))
    }

    /// The cleared chat's first attach creates its session once, with those settings.
    func testTheClearedChatCreatesItsSessionWithThoseSettings() async {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.create", .init(result: .object([
            "session_id": .string("runtime-2"), "stored_session_id": .string("fresh")
        ])))
        host.always("session.resume", .init(result: .object([
            "session_id": .string("runtime-2"), "stored_session_id": .string("fresh"), "running": .bool(false),
            "messages": .array([]), "info": .object(["profile_name": .string("default")])
        ])))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        let target = ConversationTarget.new(profile: "default", cwd: "/work/app",
                                            model: HermesCall.Model(id: "claude-opus", provider: "anthropic"))
        let engine = HermesConversation(server: URL(string: "https://hermes.example")!, connection: Self.connection,
                                        target: target, wire: BotClient(http: host.connection(Self.connection)))

        await engine.activate()
        await engine.activate()

        XCTAssertEqual(engine.connectionState, .connected)
        XCTAssertEqual(host.requests.filter { $0["method"].text == "session.create" }.compactMap { $0["params"].fields }, [[
            "profile": .string("default"), "cwd": .string("/work/app"),
            "model": .string("claude-opus"), "provider": .string("anthropic")
        ]])
    }

    // MARK: Fixture

    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")

    private var threeTurns: [BotJSON] {
        [row(1, "user", "First"), row(2, "assistant", "First answer."), row(3, "user", "Second"),
         row(4, "assistant", "Second answer."), row(5, "user", "Third"), row(6, "assistant", "Third answer.")]
    }

    /// `threeTurns` after an in-place compaction, as the host pages it: the first turn
    /// re-inserted under new ids, the middle one archived, the summary, then the last turn.
    private var compactedTurns: [BotJSON] {
        [row(7, "user", "First"), row(8, "assistant", "First answer."),
         row(3, "user", "Second", active: false), row(4, "assistant", "Second answer.", active: false),
         .object(["id": .number(9), "session_id": .string("tip"), "role": .string("assistant"),
                  "content": .string("[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted.\n"
                                     + "The user asked for two answers.\n--- END OF CONTEXT SUMMARY"),
                  "display_kind": .string("hidden"), "_compressed_summary": .bool(true), "active": .number(1)]),
         row(10, "user", "Third"), row(11, "assistant", "Third answer.")]
    }

    /// A `compressed` reply as the pin's in-process handler answers it, its `info` naming
    /// `storedKey`.
    private func compressed(removed: Int, storedKey: String = "tip") -> BotJSON {
        .object(["status": .string("compressed"), "removed": .number(Double(removed)),
                 "before_messages": .number(6), "after_messages": .number(4),
                 "summary": .object(["noop": .bool(false), "aborted": .bool(false),
                                     "headline": .string("Compressed: 6 → 4 messages"),
                                     "token_line": .string("Approx request size: ~900 → ~400 tokens"), "note": .null]),
                 "info": .object(["stored_session_id": .string(storedKey)]), "messages": .array([])])
    }

    /// Each stored key's transcript, served as one short page, and how many pages were read.
    private final class Pages: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: [BotJSON]] = [:]
        private var count = 0
        subscript(key: String) -> [BotJSON]? {
            get { lock.withLock { stored[key] } }
            set { lock.withLock { stored[key] = newValue } }
        }
        var reads: Int { lock.withLock { count } }
        func read(_ key: String) -> [BotJSON]? {
            lock.withLock {
                count += 1
                return stored[key]
            }
        }
    }

    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost
        let client: BotClient
        let pages: Pages

        @MainActor func receive(_ frame: BotJSON) { client.onEvent?(frame) }

        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    /// A chat attached to an idle session `tip` on runtime `runtime`, whose settled rows are
    /// `rows`. `info` is the snapshot's `session.info`; `catalog` answers `model.options`. A
    /// `.canonicalChat` target's title lookup finds root `root` at tip `tip`.
    private func openChat(_ rows: [BotJSON], info: [String: BotJSON] = [:], catalog: BotJSON? = nil,
                          target: ConversationTarget = .session(profile: "default", key: "tip")) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: .object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
            "messages": .array([]), "info": .object(info.merging(["profile_name": .string("default")]) { $1 })
        ])))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        if let catalog { host.always("model.options", .init(result: catalog)) }
        let client = BotClient(http: host.connection(Self.connection))
        let pages = Pages()
        pages["tip"] = rows
        _ = HermesHostFixture.configuration { request in
            let parts = request.url?.pathComponents ?? []
            guard parts.count == 5, parts[1] == "api", parts[2] == "sessions", parts[4] == "messages",
                  let rows = pages.read(parts[3]) else { return nil }
            return .json(200, .object(["session_id": .string(parts[3]), "messages": .array(rows)]))
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
        return Chat(model: model, turn: turn, host: host, client: client, pages: pages)
    }

    /// One display row as the transcript handler returns it: a live row, or one compaction
    /// archived (`active` 0, `compacted` 1).
    private func row(_ id: Int, _ role: String, _ content: String, active: Bool = true) -> BotJSON {
        .object(["id": .number(Double(id)), "session_id": .string("tip"), "role": .string(role), "content": .string(content),
                 "timestamp": .number(1_790_000_000 + Double(id)), "active": .number(active ? 1 : 0),
                 "compacted": .number(active ? 0 : 1)])
    }

    private func event(_ seq: Int, _ type: String, _ payload: [String: BotJSON] = [:]) -> BotJSON {
        .object(["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string(type),
                 "payload": .object(payload)])
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
