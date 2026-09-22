import XCTest
import Observation
import SwiftUI
import Vision
@testable import HermesMobile

@MainActor final class BotConversationTests: XCTestCase {
    func testEmptyRecentTranscriptDoesNotSuppressLoading() async {
        let cache = BotHistoryCache(), identity = connection, wire = BotFixtureWire()
        wire.history = []
        let first = BotConversation(server: server, connection: identity, profile: profile, historyCache: cache, wire: wire)
        await first.recover(); first.suspend()
        let next = BotConversation(server: server, connection: identity, profile: profile, historyCache: cache, wire: BotFixtureWire())
        XCTAssertTrue(next.messages.isEmpty)
        XCTAssertFalse(next.hasRecentTranscript, "An empty cached projection must retain the first-load skeleton")
    }

    func testRecentTranscriptRendersBeforeNetworkAndFreshHistoryReplacesIt() async throws {
        let cache = BotHistoryCache(), identity = connection, firstWire = BotFixtureWire()
        firstWire.history = [
            .object(["role": .string("tool"), "name": .string("terminal"), "context": .string("tool result")]),
            .object(["role": .string("assistant"), "text": .string(String(repeating: "long answer ", count: 2000)),
                     "reasoning": .string("settled reasoning"), "timestamp": .number(100)]),
            .object(["role": .string("assistant"), "text": .string("Worker finished"),
                     "display_kind": .string(BotDelegationCompletion.displayKind),
                     "display_metadata": .object(["worker": .string("fixture")])])
        ]
        let first = BotConversation(server: server, connection: identity, profile: profile, historyCache: cache, wire: firstWire)
        await first.recover()
        let messages = first.messages, activity = first.settledActivity
        first.suspend()
        let wire = BotFixtureWire()
        let next = BotConversation(server: server, connection: identity, profile: profile, historyCache: cache, wire: wire)
        XCTAssertEqual(next.messages, messages, "Warm entry keeps long text, metadata and delegation cards")
        XCTAssertEqual(next.settledActivity, activity)
        XCTAssertTrue(next.hasRecentTranscript)
        XCTAssertNil(next.runtime)
        XCTAssertNil(next.root, "A display snapshot must not dictate the canonical root")
        XCTAssertFalse(next.maySend)
        XCTAssertNil(next.pendingRequest)
        let parked = expectation(description: "Refresh waits on the network")
        var release: CheckedContinuation<Void, Never>?
        wire.beforeResume = { await withCheckedContinuation { release = $0; parked.fulfill() } }
        let refresh = Task { await next.recover() }
        await fulfillment(of: [parked], timeout: 3)
        XCTAssertEqual(next.messages, messages)
        wire.beforeResume = nil; release?.resume(); await refresh.value
        XCTAssertEqual(next.messages.map(\.content), ["saved"], "Fresh history replaces the cached projection, without duplicates")
        XCTAssertFalse(next.hasRecentTranscript)
        next.suspend()
    }

    func testRecentHistoryIsScopedAndChangedOrMissingCanonicalChatsDiscardIt() async {
        let cache = BotHistoryCache(), identity = connection
        let first = BotConversation(server: server, connection: identity, profile: profile, historyCache: cache, wire: BotFixtureWire())
        await first.recover(); first.suspend()
        for (host, account, root) in [(URL(string: "https://other.example")!, identity, nil as String?),
                                      (server, connection, nil), (server, identity, "different-root")] {
            let isolated = BotConversation(server: host, connection: account, profile: profile, conversation: root,
                historyCache: cache, wire: BotFixtureWire())
            XCTAssertTrue(isolated.messages.isEmpty)
        }
        let wire = BotFixtureWire(); wire.root = "new-root"
        let replacement = BotConversation(server: server, connection: identity, profile: profile, historyCache: cache, wire: wire)
        await replacement.recover()
        XCTAssertEqual(replacement.root, "new-root")
        XCTAssertEqual(replacement.connectionState, .connected)
        XCTAssertEqual(replacement.messages.first?.id, "new-root/0")
        replacement.suspend()
        let missingWire = BotFixtureWire(); missingWire.lookupFailure = .missingChat
        let missing = BotConversation(server: server, connection: identity, profile: profile, historyCache: cache, wire: missingWire)
        await missing.recover()
        XCTAssertTrue(missing.messages.isEmpty)
        XCTAssertNil(cache.recent.snapshot(for: .bot(server: server, connectionID: identity.id, profile: profile.id)))
        missing.suspend()
    }

    private let server = URL(string: "https://webui.example")!
    private var connection: BotConnection {
        BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!, username: "user", password: "fixture")
    }
    private var profile: BotProfile { BotProfile(.object(["name": .string("inbox-triage")]))! }

    private func make(_ wire: BotFixtureWire, drafts: ChatDraftStore? = nil, reconnectDelay: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) -> BotConversation {
        BotConversation(server: server, connection: connection, profile: profile, wire: wire,
                        drafts: drafts ?? ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)), reconnectDelay: reconnectDelay)
    }

    func testTransientDisconnectAutomaticallyRecoversWithoutResending() async {
        for failure in [BotFailure.transport, .rejected(503), .rejected(429)] {
            let wire = BotFixtureWire()
            let model = make(wire, reconnectDelay: { _ in })
            await model.recover()
            model.editDraft("Keep this unsent")
            let connected = expectation(description: "Automatically reconnected")
            wire.onDisconnect?(failure)
            withObservationTracking { _ = model.isReconnecting } onChange: { connected.fulfill() }
            await fulfillment(of: [connected], timeout: 3)
            XCTAssertEqual(model.connectionState, .connected)
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.draft, "Keep this unsent")
            XCTAssertEqual(wire.connectCount, 2)
            XCTAssertFalse(wire.calls.contains { ["prompt.submit", "session.steer", "session.redirect", "config.set"].contains($0.0) })
            model.suspend()
        }
    }

    func testLostSendAutomaticallyRestoresDraftWithoutResending() async {
        let waiting = expectation(description: "Automatic recovery scheduled")
        var release: CheckedContinuation<Void, Never>?
        let wire = BotFixtureWire()
        let model = make(wire, reconnectDelay: { _ in
            await withCheckedContinuation { release = $0; waiting.fulfill() }
        })
        await model.recover(); model.editDraft("Restore automatically")
        wire.submitFailure = .transport
        await model.send()
        await fulfillment(of: [waiting], timeout: 3)
        let recovered = expectation(description: "Draft restored by automatic recovery")
        withObservationTracking { _ = model.isReconnecting } onChange: { recovered.fulfill() }
        release?.resume()
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertFalse(model.uncertainSend)
        XCTAssertTrue(model.maySend)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.draft, "Restore automatically")
        XCTAssertEqual(wire.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        model.suspend()
    }

    func testSuspendingCancelsPendingAutomaticReconnect() async {
        let waiting = expectation(description: "Reconnect delay started")
        let finished = expectation(description: "Reconnect delay released")
        var release: CheckedContinuation<Void, Never>?
        let wire = BotFixtureWire()
        let model = make(wire, reconnectDelay: { _ in
            await withCheckedContinuation { release = $0; waiting.fulfill() }
            finished.fulfill()
        })
        await model.recover()
        wire.onDisconnect?(BotFailure.transport)
        await fulfillment(of: [waiting], timeout: 3)
        model.suspend()
        release?.resume()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(model.isReconnecting)
        XCTAssertEqual(wire.connectCount, 1)
        XCTAssertEqual(model.connectionState, .disconnected)
    }

    func testReconnectBacksOffAndStopsForAnAuthenticationFailure() async {
        let wire = BotFixtureWire()
        var delays: [Duration] = []
        let model = make(wire, reconnectDelay: { delay in
            delays.append(delay)
            wire.lookupFailure = delays.count < 7 ? .transport : .rejected(401)
        })
        await model.recover()
        let stopped = expectation(description: "Authentication needs user action")
        wire.onDisconnect?(BotFailure.transport)
        withObservationTracking { _ = model.isReconnecting } onChange: { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30].map { .seconds($0) })
        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertEqual(model.errorMessage, BotFailure.rejected(401).localizedDescription)
        model.suspend()
    }

    func testFailedDraftClearAfterAcknowledgmentKeepsTextDurablyHeld() async throws {
        let persistence = BotFailingDraftClear()
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire, drafts: ChatDraftStore(persistence: persistence, debounceDuration: .seconds(60)))
        await model.recover(); model.editDraft("keep after disk failure")
        await model.submit(try XCTUnwrap(model.preparePrompt(.steer)))
        XCTAssertTrue(model.uncertainSend)
        XCTAssertEqual(model.draft, "keep after disk failure")
        let saved = await persistence.load()
        XCTAssertEqual(saved[model.draftKey]?.text, "keep after disk failure")
        XCTAssertTrue(saved[model.draftKey]?.botSubmissionUncertain == true)
        model.suspend()
    }

    func testPromptModesRequireTheirOwnAcknowledgmentAndPreserveRejectedDrafts() async throws {
        for (mode, status, accepted) in [(BotPromptMode.steer, "queued", true), (.redirect, "redirected", true),
                                          (.redirect, "queued", true), (.queue, "queued", true),
                                          (.queue, "streaming", true), (.steer, "rejected", false),
                                          (.redirect, "rejected", false)] {
            let wire = BotFixtureWire(); wire.running = true
            wire.promptReply = .object(["status": .string(status), "future": .bool(true)])
            let model = make(wire); await model.recover(); model.editDraft("guide once")
            let action = try XCTUnwrap(model.preparePrompt(mode))
            await model.submit(action)
            XCTAssertEqual(model.draft, accepted ? "" : "guide once")
            XCTAssertFalse(model.uncertainSend)
            XCTAssertEqual(model.connectionState, .connected)
            let calls = wire.calls.filter { $0.0 == mode.method }
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.1["session_id"], .string("runtime"))
            XCTAssertEqual(calls.first?.1["text"], .string("guide once"))
            XCTAssertEqual(calls.first?.1["queued"], mode == .queue ? .bool(true) : nil)
            await model.submit(action)
            XCTAssertEqual(wire.calls.filter { $0.0 == mode.method }.count, 1)
            model.suspend()
        }
    }

    func testPromptRaceBeforeDispatchPreservesDraftAndNeverFallsBackToSend() async throws {
        for mode in [BotPromptMode.steer, .redirect, .queue] {
            let wire = BotFixtureWire(); wire.running = true
            let model = make(wire); await model.recover(); model.editDraft("keep")
            let action = try XCTUnwrap(model.preparePrompt(mode))
            wire.beforeDispatch = { method in
                guard method == mode.method else { return }
                wire.running = false
                wire.onEvent?(self.typed(1, "message.complete"))
            }
            await model.submit(action)
            XCTAssertFalse(model.uncertainSend)
            XCTAssertEqual(model.draft, "keep")
            XCTAssertTrue(wire.calls.allSatisfy { !["prompt.submit", "session.steer", "session.redirect"].contains($0.0) })
            model.suspend()
        }
    }

    func testInitializationRejectionAndMissingMethodDoNotLoseDraft() async throws {
        for failure in [BotFailure.rejected(4010), .rejected(-32601)] {
            let wire = BotFixtureWire(); wire.running = true; wire.submitFailure = failure
            let model = make(wire); await model.recover(); model.editDraft("not accepted")
            await model.submit(try XCTUnwrap(model.preparePrompt(.steer)))
            XCTAssertFalse(model.uncertainSend)
            XCTAssertEqual(model.draft, "not accepted")
            XCTAssertEqual(model.connectionState, .connected)
            XCTAssertEqual(model.unavailablePromptModes.contains(.steer), failure == .rejected(-32601))
            model.suspend()
        }
    }

    func testTransportFailureAndServerSideErrorNeverRetryGuidance() async throws {
        for failure in [BotFailure.transport, .rejected(5000)] {
            let wire = BotFixtureWire(); wire.running = true; wire.submitFailure = failure
            let model = make(wire); await model.recover(); model.editDraft("once")
            wire.beforeSubmit = { XCTAssertNotNil(model.submittingPrompt) }
            await model.submit(try XCTUnwrap(model.preparePrompt(.steer)))
            XCTAssertTrue(model.uncertainSend)
            XCTAssertNil(model.submittingPrompt)
            XCTAssertEqual(model.draft, "once")
            await model.recover()
            XCTAssertFalse(model.uncertainSend)
            XCTAssertNotNil(model.preparePrompt(.steer))
            XCTAssertEqual(wire.calls.filter { $0.0 == "session.steer" }.count, 1)
            model.suspend()
        }
    }

    func testLostOrUnrecognizedPromptAcknowledgmentRestoresDraftAcrossRecovery() async throws {
        for reply in [BotJSON.null, .object(["status": .string("future")]), .object(["status": .string("redirected")])] {
            let wire = BotFixtureWire(); wire.running = true; wire.promptReply = reply
            let persistence = BotMemoryDrafts()
            let model = make(wire, drafts: ChatDraftStore(persistence: persistence))
            await model.recover(); model.editDraft("hold this")
            await model.submit(try XCTUnwrap(model.preparePrompt(.steer)))
            XCTAssertTrue(model.uncertainSend)
            XCTAssertEqual(model.draft, "hold this")
            let persisted = await persistence.load()
            XCTAssertTrue(persisted[model.draftKey]?.botSubmissionUncertain == true)
            await model.recover()
            XCTAssertFalse(model.uncertainSend)
            XCTAssertNotNil(model.preparePrompt(.steer))
            XCTAssertEqual(wire.calls.filter { $0.0 == "session.steer" }.count, 1)
            model.suspend()
        }
    }

    func testDisconnectedAcknowledgmentCannotClearAnotherConnectionsDraft() async throws {
        let persistence = BotMemoryDrafts()
        let drafts = ChatDraftStore(persistence: persistence)
        let wire = BotFixtureWire(); wire.running = true
        let old = make(wire, drafts: drafts)
        let nextWire = BotFixtureWire(); nextWire.running = true
        let next = make(nextWire, drafts: drafts)
        await old.recover(); old.editDraft("old guidance")
        await next.recover(); next.editDraft("new guidance")
        let wrote = expectation(description: "Steer dispatched")
        var finish: CheckedContinuation<Void, Never>?
        wire.beforeSubmit = { await withCheckedContinuation { finish = $0; wrote.fulfill() } }
        let action = try XCTUnwrap(old.preparePrompt(.steer))
        let pending = Task { await old.submit(action) }
        await fulfillment(of: [wrote], timeout: 3)
        old.suspend()
        finish?.resume()
        await pending.value
        XCTAssertTrue(old.uncertainSend)
        XCTAssertEqual(old.draft, "old guidance")
        XCTAssertEqual(next.draft, "new guidance")
        XCTAssertNotNil(next.preparePrompt(.steer))
        let saved = await drafts.draft(for: old.draftKey)
        XCTAssertEqual(saved?.text, "old guidance")
        XCTAssertTrue(saved?.botSubmissionUncertain == true)
        next.suspend()
    }

    func testQueuedFollowUpAfterStopNeverClaimsTheQueueRemains() async throws {
        let wire = BotFixtureWire(); wire.running = true
        wire.promptReply = .object(["status": .string("queued")])
        let model = make(wire); await model.recover(); model.editDraft("next")
        await model.submit(try XCTUnwrap(model.preparePrompt(.queue)))
        XCTAssertEqual(model.draft, "")
        await model.recover()
        await model.stop(try XCTUnwrap(model.prepareStop()))
        XCTAssertFalse(model.maySend)
        // A queued envelope can still appear after Stop races the server drain.
        // Trust the next snapshot; never resend or claim the conversation is idle.
        wire.running = false; wire.queued = .object(["text": .string("server follow-up")])
        await model.recover()
        XCTAssertFalse(model.maySend)
        XCTAssertEqual(model.turn, .running)
        wire.queued = .null
        await model.recover()
        XCTAssertTrue(model.maySend)
        XCTAssertEqual(wire.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        model.suspend()
    }

    func testVoiceStopAcknowledgementClearsTheDraftWithoutStartingATurn() async throws {
        let wire = BotFixtureWire()
        wire.promptReply = .object(["voice_stopped": .bool(true)])
        let model = make(wire); await model.recover(); model.editDraft("stop speaking")
        await model.submit(try XCTUnwrap(model.preparePrompt(.send)))
        wire.running = false
        await model.recover()

        XCTAssertEqual(model.draft, "", "the host took the phrase; it must not linger as a draft")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.turn, .idle)
        XCTAssertEqual(wire.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        model.suspend()
    }

    func testEditingDraftOrChangingConnectionInvalidatesRedirectConfirmation() async throws {
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire); await model.recover(); model.editDraft("first")
        let action = try XCTUnwrap(model.preparePrompt(.redirect))
        model.editDraft("replacement")
        await model.submit(action)
        await model.recover()
        await model.submit(action)
        XCTAssertFalse(wire.calls.contains { $0.0 == "session.redirect" })
        XCTAssertEqual(model.draft, "replacement")
        model.suspend()
    }

    func testOnlyAcceptedSnapshotsPopulateTheLocalMessageCache() async throws {
        let cache = BotHistoryCache()
        let wire = BotFixtureWire()
        wire.history = [.object(["role": .string("user"), "text": .string("Newport")])]
        let server = URL(string: "https://cache.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let profile = BotProfile(.object(["name": .string("inbox-triage")]))!
        let model = BotConversation(server: server, connection: connection, profile: profile, historyCache: cache,
                                    wire: wire, drafts: ChatDraftStore(persistence: BotMemoryDrafts()))
        await model.recover()
        await model.historyCacheTask?.value
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection.id)
        let hits = try await cache.search("Newport", scope: scope, profileIDs: [profile.id])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.snapshot.root, "root")
        XCTAssertEqual(hits.first?.snapshot.tip, "tip")
        XCTAssertEqual(model.runtime, "runtime")
        wire.root = "wrong-root"
        wire.history = [.object(["role": .string("assistant"), "text": .string("replacement")])]
        await model.recover()
        await model.historyCacheTask?.value
        let rejected = try await cache.search("replacement", scope: scope, profileIDs: [profile.id])
        XCTAssertTrue(rejected.isEmpty)
        model.suspend()
    }

    func testOpenKeepsCanonicalRootTipAndRuntimeSeparate() async {
        let wire = BotFixtureWire()
        let model = make(wire)
        await model.recover()
        XCTAssertEqual(model.root, "root")
        XCTAssertEqual(model.runtime, "runtime")
        XCTAssertTrue(model.maySend)
        XCTAssertEqual(model.messages.map(\.content), ["saved"])
        XCTAssertEqual(wire.calls.map(\.0), ["session.list", "session.resume", "session.events.since", "session.resume", "model.options", "session.control.read", "subagent.list"])
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
        XCTAssertFalse(model.uncertainSend)
        XCTAssertTrue(model.maySend)
        XCTAssertEqual(wire.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        let restoredWire = BotFixtureWire()
        let restored = BotConversation(server: server, connection: model.connection, profile: profile,
                                       wire: restoredWire, drafts: ChatDraftStore(persistence: persistence))
        await restored.recover()
        XCTAssertFalse(restored.uncertainSend)
        XCTAssertEqual(restored.draft, "only once")
        XCTAssertTrue(restored.maySend)
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
            if !stopping {
                XCTAssertEqual(model.draft, "not dispatched")
                XCTAssertEqual(model.connectionState, .disconnected)
                XCTAssertEqual(model.errorMessage, BotFailure.stale.localizedDescription)
                await model.recover()
                XCTAssertTrue(model.maySend)
                XCTAssertEqual(model.draft, "not dispatched")
            }
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

    private func typed(_ seq: Int, _ type: String, _ payload: BotJSON = .null) -> BotJSON {
        var object: [String: BotJSON] = ["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string(type)]
        if payload != .null { object["payload"] = payload }
        return .object(object)
    }

    /// A host that lists the prompt in history while it is still in flight must
    /// not get a second bubble; the live prompt row only appears when history
    /// has not caught up.
    func testInFlightPromptAlreadyInHistoryDrawsOnce() async {
        let wire = BotFixtureWire(); wire.running = true
        wire.history = [.object(["role": .string("assistant"), "text": .string("saved")]),
                        .object(["role": .string("user"), "text": .string("Tell me story")])]
        wire.inflight = .object(["user": .string("Tell me story"), "assistant": .string("Once")])
        let model = make(wire); await model.recover()
        XCTAssertEqual(model.messages.map(\.content), ["saved", "Tell me story"])
        XCTAssertEqual(model.liveMessages.map(\.content), ["Once"], "the settled row already shows the prompt")

        wire.history = [.object(["role": .string("assistant"), "text": .string("saved")])]
        await model.recover()
        XCTAssertEqual(model.liveMessages.map(\.content), ["Tell me story", "Once"], "history behind: the live row fills the gap")

        // The same words sent again: the settled row is last turn's, dated before
        // this turn began, so the new prompt still shows while history lags.
        wire.history = [.object(["role": .string("user"), "text": .string("Tell me story"), "timestamp": .number(100)])]
        wire.turnStartedAt = 200
        await model.recover()
        XCTAssertEqual(model.liveMessages.map(\.content), ["Tell me story", "Once"], "an older identical prompt is not this one")
        wire.history = [.object(["role": .string("user"), "text": .string("Tell me story"), "timestamp": .number(250)])]
        await model.recover()
        XCTAssertEqual(model.liveMessages.map(\.content), ["Once"], "dated inside this turn, it is this prompt")
        model.suspend()
    }

    func testLongResponseInterleavesToolEventsThenSettlesWithoutDuplicateRows() async {
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire); await model.recover()
        wire.inflight = .object(["user": .string("Clear the inbox"), "assistant": .string("Archiving")])
        wire.onEvent?(typed(1, "message.start"))
        wire.onEvent?(typed(2, "thinking.delta", .object(["text": .string("Archive first")])))
        wire.onEvent?(typed(3, "tool.start", .object(["tool_id": .string("t1"), "name": .string("terminal"), "args": .object(["command": .string("himalaya move")])])))
        let streamed = expectation(description: "inflight snapshot published")
        withObservationTracking { _ = model.liveMessages } onChange: { streamed.fulfill() }
        wire.onEvent?(typed(4, "message.delta", .object(["text": .string("Archiving")])))
        await fulfillment(of: [streamed], timeout: 3)
        XCTAssertEqual(model.turn, .running)
        let resumes = wire.calls.filter { $0.0 == "session.resume" }.count
        wire.onEvent?(typed(5, "tool.complete", .object(["tool_id": .string("t1"), "name": .string("terminal"), "result": .object(["output": .string("ok")])])))
        wire.onEvent?(typed(6, "todo.updated", .object(["revision": .number(2), "todos": .array([
            .object(["id": .string("a"), "content": .string("Archive"), "status": .string("completed")]),
            .object(["id": .string("b"), "content": .string("Draft"), "status": .string("in_progress")])
        ])])))
        wire.onEvent?(typed(7, "todo.updated", .object(["revision": .number(1), "todos": .array([.object(["id": .string("z"), "content": .string("stale"), "status": .string("pending")])])])))
        wire.onEvent?(typed(8, "status.update", .object(["kind": .string("compacting"), "text": .string("Compacting context")])))
        wire.onEvent?(typed(9, "review.summary", .object(["text": .string("Saved a memory")])))
        XCTAssertEqual(model.liveMessages.map(\.content), ["Clear the inbox", "Archiving"])
        XCTAssertEqual(model.liveActivity.reasoning, "Archive first")
        XCTAssertEqual(model.liveActivity.toolCalls.map(\.isCompleted), [true])
        XCTAssertEqual(model.plan?.revision, 2)
        XCTAssertEqual(model.plan?.current?.content, "Draft")
        XCTAssertEqual(model.workStatus, "Compacting context")
        XCTAssertEqual(model.liveActivity.memoryNotes, ["Saved a memory"])
        wire.inflight = .object(["user": .string("Clear the inbox"), "assistant": .string("Archiving done")])
        let streamedAgain = expectation(description: "second inflight snapshot published")
        withObservationTracking { _ = model.liveMessages } onChange: { streamedAgain.fulfill() }
        wire.onEvent?(typed(10, "message.delta", .object(["text": .string(" done")])))
        await fulfillment(of: [streamedAgain], timeout: 3)
        XCTAssertEqual(wire.calls.filter { $0.0 == "session.resume" }.count, resumes + 1,
                       "activity events during known work never add snapshot reads")
        // Completion: the full snapshot carries the settled rows and the live rows go away.
        wire.running = false; wire.inflight = .null
        wire.history = [
            .object(["role": .string("user"), "text": .string("Clear the inbox")]),
            .object(["role": .string("tool"), "name": .string("terminal"), "context": .string("himalaya move")]),
            .object(["role": .string("assistant"), "text": .string("Archiving done"), "reasoning": .string("Archive first")])
        ]
        let settled = expectation(description: "full snapshot published")
        withObservationTracking { _ = model.messages } onChange: { settled.fulfill() }
        wire.onEvent?(typed(11, "message.complete", .object(["text": .string("Archiving done")])))
        await fulfillment(of: [settled], timeout: 3)
        XCTAssertEqual(model.turn, .idle)
        XCTAssertEqual(model.messages.map(\.content), ["Clear the inbox", "Archiving done"])
        XCTAssertEqual(model.settledActivity.map(\.anchorMessageID), ["root/2"])
        XCTAssertEqual(model.settledActivity[0].toolCalls.map(\.name), ["terminal"])
        XCTAssertEqual(model.settledActivity[0].reasoning, "Archive first")
        XCTAssertFalse(model.liveActivity.hasTurnWork, "settled rows replace the live rows, never both")
        XCTAssertEqual(model.liveActivity.memoryNotes, ["Saved a memory"], "notes stay until the next turn starts")
        XCTAssertNil(model.workStatus)
        wire.onEvent?(typed(12, "message.start"))
        XCTAssertTrue(model.liveActivity.memoryNotes.isEmpty)
        model.suspend()
    }

    func testReplayRebuildsCurrentTurnActivityOnlyWhenTheRingHoldsIt() async {
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire); await model.recover()
        XCTAssertFalse(model.liveActivity.hasTurnWork)
        // Continuous replay after a quiet socket: the missed events rebuild the rows.
        wire.replay = BotFixtureWire.replay(latest: 2, events: [
            typed(1, "tool.start", .object(["tool_id": .string("t1"), "name": .string("terminal")])),
            typed(2, "tool.complete", .object(["tool_id": .string("t1"), "name": .string("terminal"), "result": .string("ok")]))
        ])
        await model.recover()
        XCTAssertFalse(model.replayWasReset)
        XCTAssertEqual(model.liveActivity.toolCalls.map(\.isCompleted), [true])
        // A truncated ring that still holds the turn's start rebuilds from that start only.
        wire.replay = BotFixtureWire.replay(latest: 6, truncated: true, events: [
            typed(4, "tool.start", .object(["tool_id": .string("old"), "name": .string("terminal")])),
            typed(5, "message.start"),
            typed(6, "tool.start", .object(["tool_id": .string("new"), "name": .string("read_file")]))
        ])
        await model.recover()
        XCTAssertTrue(model.replayWasReset)
        XCTAssertEqual(model.liveActivity.toolCalls.map(\.id), ["new"])
        // Truncated without the start: partial rows and notices whose clear may sit
        // in the gap are dropped rather than shown.
        wire.onEvent?(typed(7, "notification.show", .object(["key": .string("credits"), "text": .string("Low credits")])))
        XCTAssertEqual(model.liveActivity.notices.map(\.id), ["credits"])
        wire.replay = BotFixtureWire.replay(latest: 9, truncated: true, events: [
            typed(9, "tool.start", .object(["tool_id": .string("partial"), "name": .string("terminal")]))
        ])
        await model.recover()
        XCTAssertTrue(model.replayWasReset)
        XCTAssertFalse(model.liveActivity.hasTurnWork)
        XCTAssertTrue(model.liveActivity.notices.isEmpty)
        // Duplicate sequence numbers in a replay never duplicate rows.
        wire.replay = BotFixtureWire.replay(latest: 11, events: [
            typed(10, "tool.start", .object(["tool_id": .string("t10"), "name": .string("terminal")])),
            typed(10, "tool.start", .object(["tool_id": .string("t10"), "name": .string("terminal")])),
            typed(11, "tool.start", .object(["tool_id": .string("t11"), "name": .string("terminal")]))
        ])
        await model.recover()
        XCTAssertFalse(model.replayWasReset)
        XCTAssertEqual(model.liveActivity.toolCalls.map(\.id), ["t10", "t11"])
        model.suspend()
    }

    func testSnapshotPlanIsRevisionMonotonic() async {
        let wire = BotFixtureWire()
        wire.todoState = .object(["revision": .number(5), "todos": .array([.object(["id": .string("a"), "content": .string("Ship"), "status": .string("pending")])])])
        let model = make(wire); await model.recover()
        XCTAssertEqual(model.plan?.revision, 5)
        wire.todoState = .object(["revision": .number(4), "todos": .array([.object(["id": .string("b"), "content": .string("Older"), "status": .string("pending")])])])
        await model.recover()
        XCTAssertEqual(model.plan?.items.map(\.content), ["Ship"])
        model.suspend()
    }

    func testLongInflightResponseRemainsVisibleAtLatestEdge() async throws {
        let wire = BotFixtureWire()
        wire.running = true
        wire.history = [.object(["role": .string("assistant"), "text": .string(
            (1...300).map { "\($0) SAVED HISTORY" }.joined(separator: "\n")
        )])]
        wire.inflight = .object(["assistant": .string(
            (1...100).map { "\($0) VISIBLE LIVE OUTPUT" }.joined(separator: "\n")
        )])
        let model = make(wire)
        let host = UIHostingController(rootView: BotChatView(model: model).environment(\.scenePhase, .active))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { model.suspend(); window.isHidden = true; window.rootViewController = nil }
        await model.recover()
        await renderBotFrames()
        for step in 1...6 {
            wire.inflight = .object(["assistant": .string(
                (1...(100 + step * 50)).map { "\($0) VISIBLE LIVE OUTPUT" }.joined(separator: "\n")
            )])
            let updated = expectation(description: "Stream snapshot published")
            withObservationTracking { _ = model.liveMessages } onChange: { updated.fulfill() }
            wire.onEvent?(event(step))
            await fulfillment(of: [updated], timeout: 3)
            await renderBotFrames()
            try assertBotOutputVisible(window)
        }
    }

    private func renderBotFrames() async {
        let rendered = expectation(description: "Transcript layout committed")
        let driver = BotRenderFrameDriver { rendered.fulfill() }
        driver.start()
        await fulfillment(of: [rendered], timeout: 10)
        driver.stop()
    }

    /// Reads the lower half of the window, where the latest edge of the
    /// transcript sits above the composer, so saved history scrolled off the top
    /// can never satisfy the check. The probe is a large repeated uppercase
    /// phrase, which the fast recognizer finds reliably at a fraction of the cost.
    private func assertBotOutputVisible(_ window: UIWindow) throws {
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot, quality: .medium)
        attachment.lifetime = .keepAlways
        add(attachment)
        let full = try XCTUnwrap(screenshot.cgImage)
        let lowerHalf = try XCTUnwrap(full.cropping(to: CGRect(x: 0, y: full.height / 2, width: full.width, height: full.height / 2)))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        try VNImageRequestHandler(cgImage: lowerHalf).perform([request])
        let visibleText = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        XCTAssertTrue(visibleText.contains("VISIBLE LIVE OUTPUT"), "Live response must be visible at the latest edge, got: \(visibleText)")
    }
}

/// Drives real display-link frames so a capture happens after layout, never
/// after a wall-clock sleep. `target` is how many frames to let pass: a view
/// whose content arrives from a live event needs more than the default.
@MainActor final class BotRenderFrameDriver: NSObject {
    private let completion: () -> Void
    private let target: Int
    private var link: CADisplayLink?
    private var frames = 0
    init(target: Int = 3, completion: @escaping () -> Void) {
        self.target = target
        self.completion = completion
    }
    func start() {
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick() {
        frames += 1
        if frames == target { stop(); completion() }
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
    var runtimeID = "runtime"
    var running = false
    var inflight = BotJSON.null
    /// When the current turn began, as `turn_started_at`; nil for a host that sends none.
    var turnStartedAt: Double?
    var queued = BotJSON.null
    /// Shorthand for "a command approval is blocking this session"; set
    /// `pendingApproval` directly to control the payload.
    var attention = false
    var pendingApproval: BotJSON?
    var pendingClarify = BotJSON.null
    var openRequests = BotJSON.null
    var answerRequest: ((String, [String: BotJSON]) throws -> BotJSON)?
    /// What `approval.respond` reports unblocking, and what `clarify.respond` reports.
    var approvalResolved = 1
    var clarifyStatus = "ok"
    /// What `sudo.respond` / `secret.respond` report; "ok" or "expired".
    var credentialStatus = "ok"
    var respondFailure: BotFailure?
    var todoState = BotJSON.null
    var history: [BotJSON] = [.object(["role": .string("assistant"), "text": .string("saved")])]
    var replay = BotFixtureWire.replay()
    var settingsCall: ((String, [String: BotJSON]) -> BotJSON)?
    var lookupFailure: BotFailure?
    var submitFailure: BotFailure?
    /// What `commands.catalog` answers, and what `command.dispatch` answers for a
    /// skill; nil means the host has no reply and the RPC fails.
    var catalog: BotJSON?
    /// Consumed before `catalog`, so a test can change the host's answer between reads.
    var catalogQueue: [BotJSON] = []
    var catalogFailure: BotFailure?
    var dispatch: BotJSON?
    var dispatchFailure: BotFailure?
    var promptReply: BotJSON?
    var stopFailure: BotFailure?
    var beforeDispatch: ((String) -> Void)?
    var beforeSubmit: (() async -> Void)?
    var beforeResume: (() async -> Void)?
    var transformResume: ((BotJSON) -> BotJSON)?
    var attachFile: (([String: BotJSON]) async throws -> BotJSON)?
    var imageUpload: ((Data, String, BotArtifactContext) async throws -> String)?
    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> String {
        guard let imageUpload else { throw BotFailure.unsupported }
        return try await imageUpload(data, filename, context)
    }
    var downloadArtifact: ((String, BotArtifactContext) async throws -> Data)?
    func artifactData(path: String, context: BotArtifactContext) async throws -> Data {
        guard let downloadArtifact else { throw BotArtifactFailure.unavailable }
        return try await downloadArtifact(path, context)
    }
    var connectCount = 0
    func connect() async throws { connectCount += 1 }
    func close() {}
    func call(_ method: String, _ params: [String: BotJSON], validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        beforeDispatch?(method)
        try validateDispatch?()
        calls.append((method, params))
        switch method {
        case "file.attach":
            guard let attachFile else { throw BotFailure.unsupported }
            return try await attachFile(params)
        case "session.list":
            if let lookupFailure {
                if lookupFailure == .missingChat { return .object(["sessions": .array([])]) }
                throw lookupFailure
            }
            return .object(["sessions": .array([.object(["id": .string(root), "resolved_id": .string(tip)])])])
        case "session.resume":
            await beforeResume?()
            let snapshot = BotJSON.object([
                "session_id": .string(runtimeID), "session_key": .string(tip), "running": .bool(running),
                "messages": .array(history), "inflight": inflight, "queued": queued,
                "turn_started_at": turnStartedAt.map(BotJSON.number) ?? .null,
                "pending_approval": pendingApproval ?? (attention ? BotFixtureWire.approval() : .null),
                "pending_clarify": pendingClarify, "open_requests": openRequests,
                "todo_state": todoState,
                "info": .object(["profile_name": .string("inbox-triage")])
            ])
            return transformResume?(snapshot) ?? snapshot
        case "request.answer", "clarify.lock":
            if let respondFailure { throw respondFailure }
            if let answerRequest { return try answerRequest(method, params) }
            openRequests = .array([])
            return .object(["status": .string("ok"), "remaining": .array([])])
        case "approval.respond":
            if let respondFailure { throw respondFailure }
            if approvalResolved > 0 { attention = false; pendingApproval = nil }
            return .object(["resolved": .number(Double(approvalResolved))])
        case "clarify.respond":
            if let respondFailure { throw respondFailure }
            if clarifyStatus == "ok" { pendingClarify = .null }
            return .object(["status": .string(clarifyStatus)])
        case "sudo.respond", "secret.respond", "mcp.setup.respond":
            if let respondFailure { throw respondFailure }
            return .object(["status": .string(credentialStatus)])
        case "session.events.since": return replay
        case "subagent.list": return .object(["subagents": .array([]), "delegations": .array([])])
        case "commands.catalog":
            if let catalogFailure { throw catalogFailure }
            if !catalogQueue.isEmpty { return catalogQueue.removeFirst() }
            guard let catalog else { throw BotFailure.unsupported }
            return catalog
        case "command.dispatch":
            if let dispatchFailure { throw dispatchFailure }
            guard let dispatch else { throw BotFailure.unsupported }
            return dispatch
        case "prompt.submit", "session.steer", "session.redirect":
            await beforeSubmit?()
            if let submitFailure { throw submitFailure }
            running = true
            return promptReply ?? .object(["status": .string(method == "prompt.submit" ? "streaming" : "queued")])
        case "session.interrupt":
            if let stopFailure { throw stopFailure }
            return .object(["interrupted": .bool(true)])
        default:
            if let settingsCall { return settingsCall(method, params) }
            throw BotFailure.unsupported
        }
    }
    /// The gateway's `_approval_request_payload` shape, as it reaches both the
    /// `approval.request` event and the resume snapshot.
    static func approval(id: String = "req-1", command: String = "rm -rf build",
                         choices: [String] = ["once", "session", "always", "deny"]) -> BotJSON {
        .object([
            "request_id": .string(id), "command": .string(command),
            "description": .string("recursive delete"), "pattern_key": .string("rm"),
            "choices": .array(choices.map(BotJSON.string))
        ])
    }

    /// The single-question `clarify.request` / `pending_clarify` shape.
    static func clarify(id: String = "clr-1", question: String = "Which mailbox first?",
                        choices: [String] = ["Primary (Recommended)", "Follow-ups"],
                        multiSelect: Bool = false) -> BotJSON {
        .object([
            "request_id": .string(id), "question": .string(question),
            "choices": .array(choices.map(BotJSON.string)), "multi_select": .bool(multiSelect)
        ])
    }

    static func replay(latest: Int = 0, truncated: Bool = false, epoch: String = "epoch", events: [BotJSON] = []) -> BotJSON {
        .object(["latest_seq": .number(Double(latest)), "truncated": .bool(truncated), "epoch": .string(epoch), "events": .array(events)])
    }
}

/// Fail only the acknowledged clear, after the durable admission marker succeeded.
actor BotFailingDraftClear: ChatDraftPersisting {
    private var values: [ChatDraftKey: ChatDraft] = [:]
    private var shouldFail = true
    func load() -> [ChatDraftKey: ChatDraft] { values }
    func write(_ drafts: [ChatDraftKey: ChatDraft]) throws {
        let admissionWasMarked = values.values.contains { $0.botSubmissionUncertain }
        if shouldFail && admissionWasMarked && drafts.isEmpty {
            shouldFail = false
            throw BotFailure.transport
        }
        values = drafts
    }
}
