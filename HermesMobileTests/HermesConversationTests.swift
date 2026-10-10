import XCTest
import Observation
@testable import HermesMobile

/// `HermesConversation`, the engine every Hermes chat attaches through, over #901's
/// socket-level host and `BotFixtureWire`: a stored session attaches by its key, a new
/// session is created once, a bot's chat is found by its title, frames are held and handed
/// over in order, and a drop reconnects on a backoff that only reads.
@MainActor final class HermesConversationTests: XCTestCase {
    /// A stored session resumes its own key with no title lookup, and its frames reach the
    /// owner in order: the replay, then the snapshot, then frames that landed meanwhile.
    func testASessionAttachesByItsKeyAndHandsOverOrderedFrames() async {
        let host = runningTurn()
        let (conversation, owner, _) = attach(host, .session(profile: profile, key: "tip"))
        await conversation.activate()
        XCTAssertEqual(conversation.connectionState, .connected)
        XCTAssertEqual(host.requests.compactMap { $0["method"].text }, ["session.resume", "session.events.since", "session.resume"],
                       "no session.list: only a Bot Chat is looked up by title")
        XCTAssertEqual(host.requests.first?["params"]["session_id"].text, "tip")
        XCTAssertEqual(host.transcriptReads(since: 0), [false, false], "the owner reads history itself (#1047)")
        XCTAssertEqual(owner.log, ["root tip", "replay 1", "replay 2", "replay 3", "snapshot", "connected"])

        // Seq 4 and 5 were missed while away; 6 lands live ahead of the replay reply,
        // behind a copy of 4.
        let missed = [frame(4), frame(5)]
        host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 5, events: missed),
                                                before: [missed[0], frame(6)]))
        owner.log = []
        await conversation.activate()
        XCTAssertFalse(conversation.replayWasReset)
        XCTAssertEqual(owner.log, ["root tip", "replay 4", "replay 5", "snapshot", "frame 6", "connected"])
        conversation.suspend()
    }

    /// A hole in the live stream, or a frame without a `seq`, is the rebuild signal.
    func testASessionSignalsARebuildOnAGap() async {
        let host = runningTurn()
        let (conversation, owner, client) = attach(host, .session(profile: profile, key: "tip"))
        await conversation.activate()
        owner.log = []
        client.onEvent?(frame(4))
        client.onEvent?(frame(4))
        client.onEvent?(frame(7))
        client.onEvent?(.object(["session_id": .string("other-runtime"), "seq": .number(8), "type": .string("message.delta")]))
        client.onEvent?(.object(["session_id": .string("runtime"), "type": .string("message.delta")]))
        XCTAssertEqual(owner.log, ["frame 4", "frame 7 after a gap", "lost frames"],
                       "a repeat and another runtime's frame are dropped")
        XCTAssertEqual(conversation.sequence, 7)
        conversation.suspend()
    }

    /// `session.create` mints the session once; its reduced resume reply (no `session_key`,
    /// no `running`) is accepted, and the stored key comes from `stored_session_id`. A drop
    /// reattaches to that session and only reads.
    func testANewSessionIsCreatedOnceAndAcceptsTheReducedReply() async {
        let host = BotSocketHost()
        let reduced = BotJSON.object([
            "session_id": .string("runtime"), "stored_session_id": .string("fresh"), "message_count": .number(0),
            "messages": .array([]), "info": .object(["profile_name": .string(profile)])
        ])
        host.always("session.create", .init(result: reduced))
        host.always("session.resume", .init(result: reduced))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        let (conversation, owner, client) = attach(host, .new(profile: profile), reconnectDelay: { _ in })
        await conversation.activate()
        XCTAssertEqual(conversation.connectionState, .connected)
        XCTAssertEqual(conversation.target, .session(profile: profile, key: "fresh"))
        XCTAssertEqual(conversation.storedKey, "fresh")
        XCTAssertEqual(host.requests.first?["method"].text, "session.create")
        XCTAssertEqual(host.requests.first?["params"], .object(["profile": .string(profile)]),
                       "no Bot Chat title, and not hidden")
        XCTAssertEqual(host.requests.dropFirst().compactMap { $0["params"]["session_id"].text }, ["fresh", "runtime", "fresh"])
        XCTAssertEqual(owner.log, ["root fresh", "snapshot", "connected"])

        let leaving = host.requests.count
        client.onDisconnect?(BotFailure.transport)
        let reconnected = expectation(description: "reattached after the drop")
        withObservationTracking { _ = conversation.isReconnecting } onChange: { reconnected.fulfill() }
        await fulfillment(of: [reconnected], timeout: 3)
        XCTAssertEqual(conversation.connectionState, .connected)
        XCTAssertEqual(host.requests.dropFirst(leaving).compactMap { $0["method"].text },
                       ["session.resume", "session.events.since", "session.resume"],
                       "no second session.create, and no write of any kind")
        XCTAssertEqual(host.requests.dropFirst(leaving).first?["params"]["session_id"].text, "fresh")
        conversation.suspend()
    }

    /// A bot's chat keeps the draft key it always had. Every other target has its own draft,
    /// which survives a relaunch and leaves with its connection.
    func testEachTargetKeepsItsOwnDraft() async throws {
        let server = URL(string: "https://hermes.example")!, connectionID = UUID()
        let chat = ConversationTarget.canonicalChat(profile: profile)
        let session = ConversationTarget.session(profile: profile, key: "tip")
        let targets = [chat, session, .session(profile: profile, key: "other"), .new(profile: profile)]
        XCTAssertEqual(chat.draftKey(server: server, connectionID: connectionID),
                       .bot(server: server, connectionID: connectionID, profile: profile))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let drafts = ChatDraftStore(persistence: ChatDraftFilePersistence(directoryURL: directory), debounceDuration: .seconds(60))
        for (index, target) in targets.enumerated() {
            drafts.setDraft("draft \(index)", for: target.draftKey(server: server, connectionID: connectionID))
        }
        try await drafts.flush()
        let restored = await ChatDraftFilePersistence(directoryURL: directory).load()
        XCTAssertEqual(restored.count, targets.count)
        for (index, target) in targets.enumerated() {
            XCTAssertEqual(restored[target.draftKey(server: server, connectionID: connectionID)]?.text, "draft \(index)")
        }
        await drafts.discardBotDrafts(server: server, connectionID: connectionID)
        try await drafts.flush()
        let afterRemoval = await ChatDraftFilePersistence(directoryURL: directory).load()
        XCTAssertTrue(afterRemoval.isEmpty, "a removed connection takes its session drafts too")
    }

    // MARK: A bot's chat

    /// A bot's chat is found by its exact title on every attach: the row's `id` is the
    /// canonical root, its `resolved_id` the tip `session.resume` attaches, and the runtime is
    /// the resume reply's. The resume never closes the session when the socket drops.
    func testABotChatKeepsItsRootTipAndRuntimeSeparate() async {
        let wire = BotFixtureWire()
        let (conversation, owner) = attach(wire, .canonicalChat(profile: profile))
        await conversation.activate()
        XCTAssertEqual(conversation.connectionState, .connected)
        XCTAssertEqual(conversation.root, "root")
        XCTAssertEqual(conversation.storedKey, "tip")
        XCTAssertEqual(conversation.runtime, "runtime")
        XCTAssertEqual(owner.log, ["root root", "snapshot", "connected"])
        XCTAssertEqual(wire.calls.map(\.0), ["session.list", "session.resume", "session.events.since", "session.resume"])
        XCTAssertEqual(wire.calls[1].1["session_id"], .string("tip"))
        XCTAssertEqual(wire.calls[1].1["close_on_disconnect"], .bool(false))
        conversation.suspend()
    }

    /// A compaction moves the tip and keeps the root; a replaced chat (another root under the
    /// title) is refused before any resume, which could auto-continue it, and is not retried.
    func testABotChatFollowsANewTipButRefusesAChangedRoot() async {
        let wire = BotFixtureWire()
        let (conversation, owner) = attach(wire, .canonicalChat(profile: profile))
        await conversation.activate()
        wire.tip = "compacted"
        await conversation.activate()
        XCTAssertEqual(conversation.connectionState, .connected)
        XCTAssertEqual(conversation.root, "root")
        XCTAssertEqual(conversation.storedKey, "compacted")

        wire.root = "replacement"; wire.calls = []
        await conversation.activate()
        XCTAssertEqual(wire.calls.map(\.0), ["session.list"])
        XCTAssertEqual(conversation.connectionState, .disconnected)
        XCTAssertEqual(owner.disconnects.last?.failure, .wrongIdentity)
        XCTAssertFalse(conversation.isReconnecting)
        conversation.suspend()
    }

    /// A lookup that finds no chat, or fails, never creates a replacement.
    func testAMissingOrFailedLookupNeverCreatesABotChat() async {
        for failure in [BotFailure.missingChat, .rejected(5000)] {
            let wire = BotFixtureWire(); wire.lookupFailure = failure
            let (conversation, owner) = attach(wire, .canonicalChat(profile: profile))
            await conversation.activate()
            XCTAssertEqual(wire.calls.map(\.0), ["session.list"], "\(failure)")
            XCTAssertEqual(owner.disconnects.map(\.failure), [failure])
            conversation.suspend()
        }
    }

    // MARK: Reconnecting

    /// A transient drop reattaches on its own and only reads.
    func testATransientDropReconnectsWithoutSendingAnything() async {
        for failure in [BotFailure.transport, .rejected(503), .rejected(429)] {
            let wire = BotFixtureWire()
            let (conversation, owner) = attach(wire, .canonicalChat(profile: profile), reconnectDelay: { _ in })
            await conversation.activate()
            let connected = expectation(description: "reconnected after \(failure)")
            wire.onDisconnect?(failure)
            XCTAssertEqual(owner.disconnects.map(\.retrying), [true])
            withObservationTracking { _ = conversation.isReconnecting } onChange: { connected.fulfill() }
            await fulfillment(of: [connected], timeout: 3)
            XCTAssertEqual(conversation.connectionState, .connected)
            XCTAssertEqual(wire.connectCount, 2)
            XCTAssertEqual(Set(wire.calls.map(\.0)), ["session.list", "session.resume", "session.events.since"])
            conversation.suspend()
        }
    }

    /// The backoff doubles to 30 s and stops at a refused password, which is never retried.
    func testReconnectBacksOffAndStopsForARefusedPassword() async {
        let wire = BotFixtureWire()
        var delays: [Duration] = []
        let (conversation, owner) = attach(wire, .canonicalChat(profile: profile), reconnectDelay: { delay in
            delays.append(delay)
            wire.lookupFailure = delays.count < 7 ? .transport : .rejected(401)
        })
        await conversation.activate()
        let stopped = expectation(description: "the password needs the user")
        wire.onDisconnect?(BotFailure.transport)
        withObservationTracking { _ = conversation.isReconnecting } onChange: { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30].map { .seconds($0) })
        XCTAssertEqual(conversation.connectionState, .disconnected)
        XCTAssertEqual(owner.disconnects.last?.failure, .rejected(401))
        XCTAssertEqual(owner.disconnects.last?.retrying, false)
        conversation.suspend()
    }

    /// Only what can clear on its own is retried: a proxy's 502 is, while a refused password,
    /// an address that is not a dashboard and a refused gateway upgrade wait for the user.
    func testOnlyFailuresThatCanClearOnTheirOwnRetry() async {
        let cases: [(BotFailure, Bool)] = [(.rejected(502), true), (.rejected(401), false),
                                           (.notDashboard, false), (.upgradeRefused(403), false)]
        for (failure, retries) in cases {
            let wire = BotFixtureWire(); wire.lookupFailure = failure
            var delays = 0
            let (conversation, owner) = attach(wire, .canonicalChat(profile: profile),
                                               reconnectDelay: { _ in delays += 1; throw CancellationError() })
            await conversation.activate()
            XCTAssertEqual(owner.disconnects.map(\.retrying), [retries], "\(failure)")
            XCTAssertEqual(conversation.isReconnecting, retries, "\(failure)")
            if !retries { XCTAssertEqual(delays, 0, "\(failure) is never retried on its own") }
            conversation.suspend()
        }
    }

    func testSuspendingCancelsAPendingReconnect() async {
        let waiting = expectation(description: "reconnect delay started")
        let finished = expectation(description: "reconnect delay released")
        var release: CheckedContinuation<Void, Never>?
        let wire = BotFixtureWire()
        let (conversation, _) = attach(wire, .canonicalChat(profile: profile), reconnectDelay: { _ in
            await withCheckedContinuation { release = $0; waiting.fulfill() }
            finished.fulfill()
        })
        await conversation.activate()
        wire.onDisconnect?(BotFailure.transport)
        await fulfillment(of: [waiting], timeout: 3)
        conversation.suspend()
        release?.resume()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(conversation.isReconnecting)
        XCTAssertEqual(wire.connectCount, 1)
        XCTAssertEqual(conversation.connectionState, .disconnected)
    }

    /// A screen that leaves while `session.resume` is out takes nothing from its late reply.
    func testSuspendingDuringResumeDropsTheLateReply() async {
        let wire = BotFixtureWire()
        let reached = expectation(description: "resume requested")
        var release: CheckedContinuation<Void, Never>?
        wire.beforeResume = { await withCheckedContinuation { release = $0; reached.fulfill() } }
        let (conversation, owner) = attach(wire, .canonicalChat(profile: profile))
        let task = Task { await conversation.activate() }
        await fulfillment(of: [reached], timeout: 2)
        conversation.suspend()
        release?.resume()
        await task.value
        XCTAssertEqual(owner.log, ["root root"])
        XCTAssertEqual(wire.calls.map(\.0), ["session.list", "session.resume"])
        XCTAssertEqual(conversation.connectionState, .disconnected)
    }

    /// The host answers 4007 while it swaps in a replacement runtime and 4009 while an
    /// interrupt settles: both clear on their own, so the attach retries quietly.
    func testAResumeRefusedWhileTheHostSwapsOrSettlesTheRuntimeReconnects() async {
        for code in [4007, 4009] {
            let host = runningTurn()
            host.next("session.resume", .init(error: code))
            var delays: [Duration] = []
            let (conversation, owner, _) = attach(host, .session(profile: profile, key: "tip"),
                                                  reconnectDelay: { delays.append($0) })
            await conversation.activate()
            XCTAssertTrue(conversation.isReconnecting, "\(code)")
            XCTAssertEqual(owner.disconnects.map(\.retrying), [true], "\(code)")
            let connected = expectation(description: "reconnected after \(code)")
            withObservationTracking { _ = conversation.isReconnecting } onChange: { connected.fulfill() }
            await fulfillment(of: [connected], timeout: 3)
            XCTAssertEqual(conversation.connectionState, .connected, "\(code)")
            XCTAssertEqual(delays, [.seconds(1)], "\(code)")
            conversation.suspend()
        }
    }

    func testAResumeRefusalThatOutlastsAMinuteStops() async {
        let host = runningTurn()
        host.always("session.resume", .init(error: 4007))
        var clock = ContinuousClock.now
        var delays: [Duration] = []
        let (conversation, owner, _) = attach(host, .session(profile: profile, key: "tip"), now: { clock },
                                              reconnectDelay: { delays.append($0); clock = clock.advanced(by: $0) })
        await conversation.activate()
        let stopped = expectation(description: "the refusals outlasted the window")
        withObservationTracking { _ = conversation.isReconnecting } onChange: { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30].map { .seconds($0) }, "refused at 0, 1, 3, 7, 15, 31 and 61 s")
        XCTAssertEqual(conversation.connectionState, .disconnected)
        XCTAssertEqual(owner.disconnects.last?.failure, .rejected(4007))
        XCTAssertEqual(owner.disconnects.last?.retrying, false)
        XCTAssertEqual(Set(host.requests.compactMap { $0["method"].text }), ["session.resume"],
                       "a reconnect only reads")
        conversation.suspend()
    }

    /// Only `session.resume`'s refusals wait out the window.
    func testA4007FromTheBotChatLookupIsNotRetried() async {
        let wire = BotFixtureWire(); wire.lookupFailure = .rejected(4007)
        let (conversation, owner) = attach(wire, .canonicalChat(profile: profile),
                                           reconnectDelay: { _ in XCTFail("a lookup refusal is never retried") })
        await conversation.activate()
        XCTAssertFalse(conversation.isReconnecting)
        XCTAssertEqual(owner.disconnects.map(\.retrying), [false])
        conversation.suspend()
    }

    // MARK: Held frames

    /// The host can write a frame after reading the replay it is about to send: it is handed
    /// over once, after the replay, and the cursor never moves back.
    func testAFrameAheadOfAnUnchangedReplayIsHandedOverOnceAfterIt() async {
        let host = runningTurn()
        let (conversation, owner, _) = attach(host, .session(profile: profile, key: "tip"))
        await conversation.activate()
        host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 3), before: [frame(4)]))
        owner.log = []
        await conversation.activate()
        XCTAssertFalse(conversation.replayWasReset)
        XCTAssertEqual(conversation.sequence, 4)
        XCTAssertEqual(owner.log, ["root tip", "snapshot", "frame 4", "connected"])
        conversation.suspend()
    }

    /// A held frame past a hole in the replay is handed over as a gap.
    func testAGapAfterTheHeldFramesIsHandedOverAsAGap() async {
        let host = runningTurn()
        let (conversation, owner, _) = attach(host, .session(profile: profile, key: "tip"))
        await conversation.activate()
        host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 4, events: [frame(4)]),
                                                before: [frame(9)]))
        owner.log = []
        await conversation.activate()
        XCTAssertEqual(conversation.sequence, 9)
        XCTAssertEqual(owner.log, ["root tip", "replay 4", "snapshot", "frame 9 after a gap", "connected"])
        conversation.suspend()
    }

    /// Past the replay ring's 512 frames the hold has lost some, so the owner rebuilds
    /// instead of applying what was kept.
    func testFramesPastTheHoldLimitAreLost() async {
        let host = runningTurn()
        let (conversation, owner, _) = attach(host, .session(profile: profile, key: "tip"))
        await conversation.activate()
        let flood = (4...(4 + HermesConversation.heldFrameLimit)).map(frame)
        host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 3), before: flood))
        owner.log = []
        await conversation.activate()
        XCTAssertTrue(conversation.replayWasReset)
        XCTAssertEqual(owner.log, ["root tip", "snapshot", "lost frames", "connected"])
        conversation.suspend()
    }

    private let profile = "inbox-triage"

    /// A host whose replay holds the running turn through seq 3.
    private func runningTurn() -> BotSocketHost {
        let host = BotSocketHost()
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 3, events: [frame(1), frame(2), frame(3)])))
        return host
    }

    /// An engine on `target` over a fresh connection to `host`, with an owner that logs.
    private func attach(_ host: BotSocketHost, _ target: ConversationTarget,
                        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
                        reconnectDelay: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
        -> (HermesConversation, RecordingOwner, BotClient) {
        addTeardownBlock { HermesHostFixture.reset() }
        let client = BotClient(http: host.connection(record))
        let (conversation, owner) = attach(client, target, now: now, reconnectDelay: reconnectDelay)
        return (conversation, owner, client)
    }

    /// An engine on `target` over `wire`, with an owner that logs.
    private func attach(_ wire: any BotTransport, _ target: ConversationTarget,
                        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
                        reconnectDelay: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
        -> (HermesConversation, RecordingOwner) {
        let conversation = HermesConversation(server: URL(string: "https://hermes.example")!, connection: record,
                                              target: target, wire: wire, reconnectDelay: reconnectDelay, now: now)
        let owner = RecordingOwner()
        conversation.owner = owner
        return (conversation, owner)
    }

    private let record = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                       username: "user", password: "fixture")

    private func frame(_ seq: Int) -> BotJSON {
        .object(["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string("message.delta"),
                 "payload": .object(["text": .string("part \(seq)")])])
    }
}

/// Logs what the engine hands over, in order.
@MainActor private final class RecordingOwner: HermesConversationOwner {
    var log: [String] = []

    func conversationDidReset() {}
    func conversationDidIdentify(root: String) { log.append("root \(root)") }
    func conversationDidReplay(_ reply: BotJSON, frames: [BotJSON]) {
        log += frames.map { "replay \($0["seq"].integer ?? 0)" }
    }
    func conversationDidReadSnapshot(_ snapshot: BotJSON, runtime: String, attempt: Int) async throws { log.append("snapshot") }
    func conversationDidConnect(runtime: String, attempt: Int) async throws { log.append("connected") }
    func conversation(didReceive frame: BotJSON, afterGap: Bool) {
        log.append("frame \(frame["seq"].integer ?? 0)" + (afterGap ? " after a gap" : ""))
    }
    func conversationDidLoseFrames() { log.append("lost frames") }
    struct Disconnect: Equatable { let failure: BotFailure; let retrying: Bool }
    var disconnects: [Disconnect] = []
    func conversationDidDisconnect(_ failure: BotFailure, retrying: Bool) { disconnects.append(.init(failure: failure, retrying: retrying)) }
}
