import XCTest
import Observation
import SwiftUI
import Vision
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

    private func typed(_ seq: Int, _ type: String, _ payload: BotJSON = .null) -> BotJSON {
        var object: [String: BotJSON] = ["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string(type)]
        if payload != .null { object["payload"] = payload }
        return .object(object)
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
        for step in 1...12 {
            wire.inflight = .object(["assistant": .string(
                (1...(100 + step * 25)).map { "\($0) VISIBLE LIVE OUTPUT" }.joined(separator: "\n")
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

    private func assertBotOutputVisible(_ window: UIWindow) throws {
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: XCTUnwrap(screenshot.cgImage)).perform([request])
        let visibleText = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        XCTAssertTrue(visibleText.contains("VISIBLE LIVE OUTPUT"), "Live response must be visible, got: \(visibleText)")
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
    var running = false
    var inflight = BotJSON.null
    /// Shorthand for "a command approval is blocking this session"; set
    /// `pendingApproval` directly to control the payload.
    var attention = false
    var pendingApproval: BotJSON?
    var pendingClarify = BotJSON.null
    /// What `approval.respond` reports unblocking, and what `clarify.respond` reports.
    var approvalResolved = 1
    var clarifyStatus = "ok"
    var respondFailure: BotFailure?
    var todoState = BotJSON.null
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
                "messages": .array(history), "inflight": inflight,
                "pending_approval": pendingApproval ?? (attention ? BotFixtureWire.approval() : .null),
                "pending_clarify": pendingClarify,
                "todo_state": todoState,
                "info": .object(["profile_name": .string("inbox-triage")])
            ])
        case "approval.respond":
            if let respondFailure { throw respondFailure }
            if approvalResolved > 0 { attention = false; pendingApproval = nil }
            return .object(["resolved": .number(Double(approvalResolved))])
        case "clarify.respond":
            if let respondFailure { throw respondFailure }
            if clarifyStatus == "ok" { pendingClarify = .null }
            return .object(["status": .string(clarifyStatus)])
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
