import XCTest
import Observation
@testable import HermesMobile

@MainActor final class BotConversationTests: XCTestCase {
    private let server = URL(string: "https://webui.example")!
    private var connection: BotConnection {
        BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!, username: "user", password: "fixture")
    }
    private var profile: BotProfile { BotProfile(.object(["name": .string("inbox-triage")]))! }

    private func make(_ wire: BotFixtureWire, drafts: ChatDraftStore? = nil) -> BotConversation {
        BotConversation(server: server, connection: connection, profile: profile, wire: wire,
                        drafts: drafts ?? ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)))
    }

    func testOpenKeepsCanonicalRootTipAndRuntimeSeparate() async {
        let wire = BotFixtureWire()
        let model = make(wire)
        await model.recover()
        XCTAssertEqual(model.root, "root")
        XCTAssertEqual(model.runtime, "runtime")
        XCTAssertTrue(model.maySend)
        XCTAssertEqual(model.messages.map(\.content), ["saved"])
        XCTAssertEqual(wire.calls.map(\.0), ["session.list", "session.resume", "session.events.since", "session.resume"])
        XCTAssertEqual(wire.calls[1].1["session_id"], .string("tip"))
        XCTAssertEqual(wire.calls[1].1["close_on_disconnect"], .bool(false))
        model.suspend()
    }

    func testChangedRootRejectedBeforeResumeAndSavedHistoryRetained() async {
        let wire = BotFixtureWire(); let model = make(wire)
        await model.recover()
        wire.root = "replacement"; wire.calls = []
        await model.recover()
        XCTAssertEqual(wire.calls.map(\.0), ["session.list"])
        XCTAssertEqual(model.messages.map(\.content), ["saved"])
        XCTAssertFalse(model.maySend)
        model.suspend()
    }

    func testCompactionLoadsNewTipWithStableRoot() async {
        let wire = BotFixtureWire(); let model = make(wire)
        await model.recover()
        wire.tip = "compacted"; wire.history = [.object(["role": .string("assistant"), "text": .string("compacted history")])]
        await model.recover()
        XCTAssertEqual(model.root, "root")
        XCTAssertEqual(model.messages.map(\.content), ["compacted history"])
        XCTAssertTrue(model.maySend)
        model.suspend()
    }

    func testMissingAndFailedLookupsNeverCreateReplacement() async {
        for failure in [BotFailure.missingChat, .rejected(5000)] {
            let wire = BotFixtureWire(); wire.lookupFailure = failure
            let model = make(wire)
            await model.recover()
            XCTAssertFalse(model.maySend)
            XCTAssertEqual(wire.calls.map(\.0), ["session.list"])
            model.suspend()
        }
    }

    func testExistingEmptyHistoryCanSend() async {
        let wire = BotFixtureWire(); wire.history = []
        let model = make(wire); await model.recover()
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertTrue(model.maySend)
        model.suspend()
    }

    func testAmbiguousSendPersistsBeforeDispatchAndNeverRetriesAfterReopen() async throws {
        let persistence = BotMemoryDrafts()
        let drafts = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(60))
        let wire = BotFixtureWire(); wire.submitFailure = .transport
        let model = make(wire, drafts: drafts)
        await model.recover(); model.editDraft("only once")
        wire.beforeSubmit = {
            let saved = await persistence.load()
            XCTAssertTrue(saved.values.first?.botSubmissionUncertain == true)
        }
        await model.send()
        XCTAssertTrue(model.uncertainSend)
        XCTAssertFalse(model.maySend)
        await model.recover()
        await model.send()
        XCTAssertEqual(wire.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        let restoredWire = BotFixtureWire()
        let restored = BotConversation(server: server, connection: model.connection, profile: profile,
                                       wire: restoredWire, drafts: ChatDraftStore(persistence: persistence))
        await restored.recover()
        XCTAssertTrue(restored.uncertainSend)
        XCTAssertEqual(restored.draft, "only once")
        XCTAssertFalse(restored.maySend)
        model.suspend(); restored.suspend()
    }

    func testDefiniteRejectionPreservesSendableTextAfterRecovery() async {
        let wire = BotFixtureWire(); wire.submitFailure = .rejected(4090)
        let model = make(wire)
        await model.recover(); model.editDraft("keep this")
        await model.send()
        XCTAssertEqual(model.draft, "keep this")
        XCTAssertFalse(model.uncertainSend)
        XCTAssertFalse(model.maySend)
        await model.recover()
        XCTAssertTrue(model.maySend)
        model.suspend()
    }

    func testAcceptedSubmissionClearsPersistentDraft() async {
        let wire = BotFixtureWire(); let model = make(wire)
        await model.recover(); model.editDraft("accepted")
        await model.send()
        XCTAssertEqual(model.draft, "")
        XCTAssertFalse(model.uncertainSend)
        XCTAssertFalse(model.maySend)
        XCTAssertEqual(wire.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        model.suspend()
    }

    func testStopAcknowledgementNeverClaimsIdleAndActionIsSingleUse() async throws {
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire); await model.recover()
        let action = try XCTUnwrap(model.prepareStop())
        await model.stop(action)
        XCTAssertFalse(model.maySend)
        XCTAssertFalse(model.mayStop)
        await model.stop(action)
        XCTAssertEqual(wire.calls.filter { $0.0 == "session.interrupt" }.count, 1)
        model.suspend()
    }

    func testLostStopDoesNotRetryAndRecoveredIdleClearsUncertainty() async throws {
        let wire = BotFixtureWire(); wire.running = true; wire.stopFailure = .transport
        let model = make(wire); await model.recover()
        let action = try XCTUnwrap(model.prepareStop())
        await model.stop(action)
        await model.recover()
        XCTAssertTrue(model.uncertainStop)
        XCTAssertFalse(model.maySend)
        await model.stop(action)
        wire.running = false
        await model.recover()
        XCTAssertFalse(model.uncertainStop)
        XCTAssertTrue(model.maySend)
        XCTAssertEqual(wire.calls.filter { $0.0 == "session.interrupt" }.count, 1)
        model.suspend()
    }

    func testStaleUnsentStopCannotAffectLaterDesktopWork() async throws {
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire); await model.recover()
        let action = try XCTUnwrap(model.prepareStop())
        wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(1), "type": .string("message.complete")]))
        await model.recover()
        await model.stop(action)
        XCTAssertTrue(wire.calls.allSatisfy { $0.0 != "session.interrupt" })
        model.suspend()
    }

    func testPendingApprovalAndQuietWorkKeepStopAndBlockSend() async {
        for attention in [false, true] {
            let wire = BotFixtureWire(); wire.running = true; wire.attention = attention
            let model = make(wire); await model.recover()
            XCTAssertEqual(model.turn, attention ? .needsAttention : .running)
            XCTAssertTrue(model.mayStop)
            XCTAssertFalse(model.maySend)
            model.suspend()
        }
    }

    func testReplayFaultsReplaceHistoryWithoutAppendingOverlap() async {
        let wire = BotFixtureWire(); let model = make(wire)
        await model.recover()
        for replay in [
            BotFixtureWire.replay(latest: 3, truncated: true),
            BotFixtureWire.replay(latest: 1),
            BotFixtureWire.replay(latest: 0, epoch: "restart"),
            BotFixtureWire.replay(latest: 4, events: [event(4), event(4)])
        ] {
            wire.replay = replay
            await model.recover()
            XCTAssertTrue(model.replayWasReset)
            XCTAssertEqual(model.messages.map(\.content), ["saved"])
        }
        model.suspend()
    }

    func testAuthUnsupportedOwnershipAndOversizedHistoryBlockSend() async {
        for code in [401, 403, -32601, 4090, 4130] {
            let wire = BotFixtureWire(); wire.lookupFailure = .rejected(code)
            let model = make(wire); await model.recover()
            XCTAssertFalse(model.maySend)
            XCTAssertNotNil(model.errorMessage)
            model.suspend()
        }
    }

    func testSuspendingDuringResumeRejectsLateHistoryAndCommands() async {
        let wire = BotFixtureWire()
        let reached = expectation(description: "resume requested")
        var release: CheckedContinuation<Void, Never>?
        wire.beforeResume = {
            await withCheckedContinuation { continuation in release = continuation; reached.fulfill() }
        }
        let model = make(wire)
        let task = Task { await model.recover() }
        await fulfillment(of: [reached], timeout: 2)
        model.suspend()
        release?.resume()
        await task.value
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertFalse(model.maySend)
        XCTAssertEqual(wire.calls.map(\.0), ["session.list", "session.resume"])
    }

    func testLiveEventsReplaceInflightSnapshotsWithoutDuplicatingText() async {
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire); await model.recover()
        wire.inflight = .object(["user": .string("question"), "assistant": .string("first second")])
        let updated = expectation(description: "inflight snapshot published")
        withObservationTracking {
            _ = model.liveMessages
        } onChange: { updated.fulfill() }
        wire.onEvent?(event(1))
        wire.onEvent?(event(1))
        wire.onEvent?(event(2))
        await fulfillment(of: [updated], timeout: 3)
        XCTAssertEqual(model.liveMessages.map(\.content), ["question", "first second"])
        XCTAssertEqual(model.messages.map(\.content), ["saved"])
        XCTAssertEqual(wire.calls.filter { $0.0 == "session.resume" && $0.1["omit_messages"] == .bool(true) }.count, 1)
        model.suspend()
        let retained = model.liveMessages
        wire.inflight = .object(["assistant": .string("late old connection")])
        wire.onEvent?(event(3))
        XCTAssertEqual(model.liveMessages, retained)
        XCTAssertEqual(model.turn, .unknown)
    }

    func testSwitchingConnectionWithSameProfileRejectsOldSubmissionResult() async {
        let persistence = BotMemoryDrafts()
        let drafts = ChatDraftStore(persistence: persistence)
        let oldWire = BotFixtureWire()
        let old = make(oldWire, drafts: drafts)
        await old.recover(); old.editDraft("old connection")
        let dispatched = expectation(description: "old send dispatched")
        var release: CheckedContinuation<Void, Never>?
        oldWire.beforeSubmit = {
            await withCheckedContinuation { continuation in release = continuation; dispatched.fulfill() }
        }
        let task = Task { await old.send() }
        await fulfillment(of: [dispatched], timeout: 2)
        old.suspend()
        let next = make(BotFixtureWire(), drafts: drafts)
        await next.recover(); next.editDraft("new connection")
        release?.resume(); await task.value
        XCTAssertEqual(next.draft, "new connection")
        XCTAssertTrue(next.maySend)
        let held = await drafts.draft(for: old.draftKey)
        XCTAssertTrue(held?.botSubmissionUncertain == true)
        XCTAssertEqual(held?.text, "old connection")
        next.suspend()
    }

    func testDesktopBoundaryBeforeSocketDispatchRejectsUnsentCommands() async throws {
        for stopping in [false, true] {
            let wire = BotFixtureWire(); wire.running = stopping
            let model = make(wire); await model.recover()
            wire.beforeDispatch = { method in
                guard ["prompt.submit", "session.interrupt"].contains(method) else { return }
                wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(1), "type": .string("message.start")]))
            }
            if stopping { await model.stop(try XCTUnwrap(model.prepareStop())) }
            else { model.editDraft("not dispatched"); await model.send() }
            XCTAssertTrue(wire.calls.allSatisfy { !["prompt.submit", "session.interrupt"].contains($0.0) })
            XCTAssertFalse(model.uncertainSend)
            XCTAssertFalse(model.uncertainStop)
            if !stopping { XCTAssertEqual(model.draft, "not dispatched") }
            model.suspend()
        }
    }

    func testLiveSequenceRegressionInvalidatesPreparedStopUntilSnapshot() async throws {
        let wire = BotFixtureWire(); wire.running = true
        wire.replay = BotFixtureWire.replay(latest: 10)
        let model = make(wire); await model.recover()
        let action = try XCTUnwrap(model.prepareStop())
        wire.onEvent?(event(1))
        XCTAssertTrue(model.replayWasReset)
        XCTAssertEqual(model.turn, .unknown)
        XCTAssertFalse(model.mayStop)
        await model.stop(action)
        XCTAssertTrue(wire.calls.allSatisfy { $0.0 != "session.interrupt" })
        model.suspend()
    }

    private func event(_ seq: Int) -> BotJSON {
        .object(["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string("message.delta")])
    }
}

actor BotMemoryDrafts: ChatDraftPersisting {
    var values: [ChatDraftKey: ChatDraft] = [:]
    func load() -> [ChatDraftKey: ChatDraft] { values }
    func write(_ drafts: [ChatDraftKey: ChatDraft]) { values = drafts }
}

@MainActor final class BotFixtureWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var calls: [(String, [String: BotJSON])] = []
    var root = "root"
    var tip = "tip"
    var running = false
    var inflight = BotJSON.null
    var attention = false
    var history: [BotJSON] = [.object(["role": .string("assistant"), "text": .string("saved")])]
    var replay = BotFixtureWire.replay()
    var lookupFailure: BotFailure?
    var submitFailure: BotFailure?
    var stopFailure: BotFailure?
    var beforeDispatch: ((String) -> Void)?
    var beforeSubmit: (() async -> Void)?
    var beforeResume: (() async -> Void)?
    func connect() async throws {}
    func close() {}
    func call(_ method: String, _ params: [String: BotJSON], validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        beforeDispatch?(method)
        try validateDispatch?()
        calls.append((method, params))
        switch method {
        case "session.list":
            if let lookupFailure {
                if lookupFailure == .missingChat { return .object(["sessions": .array([])]) }
                throw lookupFailure
            }
            return .object(["sessions": .array([.object(["id": .string(root), "resolved_id": .string(tip)])])])
        case "session.resume":
            await beforeResume?()
            return .object([
                "session_id": .string("runtime"), "session_key": .string(tip), "running": .bool(running),
                "messages": .array(history), "inflight": inflight, "pending_approval": attention ? .object(["id": .string("approval")]) : .null,
                "info": .object(["profile_name": .string("inbox-triage")])
            ])
        case "session.events.since": return replay
        case "prompt.submit":
            await beforeSubmit?()
            if let submitFailure { throw submitFailure }
            running = true
            return .object(["status": .string("streaming")])
        case "session.interrupt":
            if let stopFailure { throw stopFailure }
            return .object(["interrupted": .bool(true)])
        default: throw BotFailure.unsupported
        }
    }
    static func replay(latest: Int = 0, truncated: Bool = false, epoch: String = "epoch", events: [BotJSON] = []) -> BotJSON {
        .object(["latest_seq": .number(Double(latest)), "truncated": .bool(truncated), "epoch": .string(epoch), "events": .array(events)])
    }
}
