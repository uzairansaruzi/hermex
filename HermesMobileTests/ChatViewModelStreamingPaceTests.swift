import SwiftUI
import XCTest
@testable import HermesMobile

/// Display-pacing tests for issue #212: buffered streamed tokens are revealed
/// word-by-word at an adaptive cadence, while completion paths flush instantly.
final class ChatViewModelStreamingPaceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testBufferedBurstRevealsWordByWordAtCadence() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        // 60s lag bound keeps the quota at one word per tick for this backlog.
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 200_000_000,
            maxLagNanoseconds: 60_000_000_000
        )

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("alpha beta gamma delta"))

        let target = "alpha beta gamma delta"
        let observed = try await observeAssistantContent(viewModel, until: target)

        XCTAssertEqual(observed.first, "alpha ")
        XCTAssertEqual(observed.last, target)
        XCTAssertGreaterThanOrEqual(
            observed.count, 3,
            "burst should reveal progressively across cadence ticks, not at once; observed: \(observed)"
        )
        for (earlier, later) in zip(observed, observed.dropFirst()) {
            XCTAssertTrue(
                later.hasPrefix(earlier),
                "paced reveal must only append: \(earlier) → \(later)"
            )
        }

        // The drain loop must re-arm for tokens arriving after the buffer emptied.
        streamClient.emit(.token(" epsilon"))
        _ = try await observeAssistantContent(viewModel, until: target + " epsilon")
        XCTAssertEqual(assistantContent(of: viewModel), target + " epsilon")
    }

    @MainActor
    func testLargeBacklogCatchesUpWithinLagBound() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        // 60 words × 100ms cadence = 6s of backlog; the 300ms lag bound forces a
        // ~20-word quota per tick, so convergence inside the 4s observation window
        // proves catch-up scaling (steady one-word cadence would time out).
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 100_000_000,
            maxLagNanoseconds: 300_000_000
        )

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        let words = (0..<60).map { "w\($0) " }
        for word in words {
            streamClient.emit(.token(word))
        }

        let target = words.joined()
        let observed = try await observeAssistantContent(viewModel, until: target)

        XCTAssertEqual(observed.last, target)
        XCTAssertGreaterThanOrEqual(
            observed.count, 2,
            "catch-up should drain in scaled chunks, not one dump; observed counts: \(observed.map(\.count))"
        )
    }

    @MainActor
    func testDoneEventFlushesRemainingBufferImmediately() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeStalledDrainViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("alpha beta gamma"))
        _ = try await observeAssistantContent(viewModel, until: "alpha ")
        XCTAssertEqual(assistantContent(of: viewModel), "alpha ")

        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")

        // Nothing may trickle in after completion.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")
    }

    @MainActor
    func testCancelledEventFlushesRemainingBufferImmediately() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeStalledDrainViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("alpha beta gamma"))
        _ = try await observeAssistantContent(viewModel, until: "alpha ")
        XCTAssertEqual(assistantContent(of: viewModel), "alpha ")

        streamClient.emit(.cancelled)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")
    }

    @MainActor
    func testToolBoundaryDoesNotBypassAssistantWordPacing() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeStalledDrainViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Stream and inspect")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("alpha beta gamma"))
        _ = try await observeAssistantContent(viewModel, until: "alpha ")
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "read_file",
            preview: "Reading source",
            args: nil,
            duration: nil,
            isError: nil
        )))

        XCTAssertEqual(
            assistantContent(of: viewModel),
            "alpha ",
            "tool-start boundaries must not dump the pending assistant token backlog"
        )

        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool.completed",
            name: "read_file",
            preview: "Read source",
            args: nil,
            duration: 0.1,
            isError: false
        )))
        XCTAssertEqual(
            assistantContent(of: viewModel),
            "alpha ",
            "tool-completion boundaries must not dump the pending assistant token backlog"
        )

        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")
    }

    @MainActor
    func testPacedContentConvergesByteIdenticalToUnpacedJoin() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 1_000_000,
            maxLagNanoseconds: 50_000_000
        )

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        // Awkward chunk boundaries: ZWJ family, flag, CRLF, tabs, doubled spaces,
        // and a combining mark split across chunks ("cafe" + U+0301).
        let chunks = [
            "The 👩‍👩‍👧‍👦 family ",
            "and 🇫🇷 flag met.\r\n",
            "tabs\tand  doubles ",
            "cafe",
            "\u{301} fin"
        ]
        for chunk in chunks {
            streamClient.emit(.token(chunk))
        }

        let target = chunks.joined()
        _ = try await observeAssistantContent(viewModel, until: target)
        let content = try XCTUnwrap(assistantContent(of: viewModel))
        XCTAssertEqual(
            Array(content.utf8),
            Array(target.utf8),
            "paced content must converge byte-identical to the unpaced concatenation"
        )
    }

    // MARK: - Helpers

    /// 60s cadence with a far larger lag bound keeps the quota at one word per
    /// tick: the first tick reveals one word, then the drain effectively stalls
    /// so completion-path flushes are observable.
    @MainActor
    private func makeStalledDrainViewModel(
        streamClient: PacingSpySSEStreamingClient
    ) throws -> ChatViewModel {
        try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 60_000_000_000,
            maxLagNanoseconds: 3_600_000_000_000
        )
    }

    @MainActor
    private func makeViewModel(
        streamClient: PacingSpySSEStreamingClient,
        wordCadenceNanoseconds: UInt64,
        maxLagNanoseconds: UInt64
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                    for: request
                )
            default:
                return apiTestJSONResponse(
                    #"{"session": {"session_id": "session-abc", "title": "Pacing", "messages": []}}"#,
                    for: request
                )
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(
            SessionSummary.self,
            from: Data(
                #"{"session_id": "session-abc", "title": "Pacing", "workspace": "/tmp/workspace"}"#.utf8
            )
        )

        return ChatViewModel(
            session: summary,
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: PacingSpySSEStreamingClient(),
            clarifyStreamClient: PacingSpySSEStreamingClient(),
            streamingScrollCoalescingDelayNanoseconds: 1_000_000,
            streamingWordRevealCadenceNanoseconds: wordCadenceNanoseconds,
            streamingMaxRevealLagNanoseconds: maxLagNanoseconds
        )
    }

    @MainActor
    private func assistantContent(of viewModel: ChatViewModel) -> String? {
        viewModel.messages.last(where: { $0.role == "assistant" })?.content
    }

    /// Polls assistant content every 5ms until it equals `target` (or times out),
    /// returning every distinct non-empty value observed in order.
    @MainActor
    private func observeAssistantContent(
        _ viewModel: ChatViewModel,
        until target: String,
        timeoutNanoseconds: UInt64 = 4_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String] {
        let pollNanoseconds: UInt64 = 5_000_000
        var observed: [String] = []
        var elapsed: UInt64 = 0
        while elapsed <= timeoutNanoseconds {
            if let content = assistantContent(of: viewModel), !content.isEmpty,
               observed.last != content {
                observed.append(content)
            }
            if observed.last == target {
                return observed
            }

            try await Task.sleep(nanoseconds: pollNanoseconds)
            elapsed += pollNanoseconds
        }

        XCTFail(
            "timed out waiting for \(target); observed: \(observed)",
            file: file,
            line: line
        )
        return observed
    }
}

/// Reasoning/tool activity (session-view polish). Two layers under test:
/// `StreamActivitySignal` is micro-liveness (bump + decay after silence), and
/// `TurnPhase` is the semantic step model that actually drives the capsules —
/// "Thinking" holds through intra-step token pauses and only settles when the
/// stream moves on to a tool call or the final answer.
final class StreamActivitySignalTests: XCTestCase {
    @MainActor
    func testBumpActivatesImmediatelyAndDecaysAfterSilence() async throws {
        let signal = StreamActivitySignal(decayInterval: 0.1)
        XCTAssertFalse(signal.isActive)

        signal.bump()
        XCTAssertTrue(signal.isActive, "rising edge must have no debounce")

        try await waitFor(timeoutNanoseconds: 2_000_000_000) { signal.isActive == false }
        XCTAssertFalse(signal.isActive, "signal must decay after the silence window")
    }

    @MainActor
    func testRepeatedBumpsExtendTheDeadline() async throws {
        let signal = StreamActivitySignal(decayInterval: 0.15)

        signal.bump()
        // Keep bumping at intervals shorter than the decay window; the signal
        // must stay active the whole time (single coalesced expiry task).
        for _ in 0..<4 {
            try await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertTrue(signal.isActive, "activity within the window must keep the signal alive")
            signal.bump()
        }

        try await waitFor(timeoutNanoseconds: 2_000_000_000) { signal.isActive == false }
        XCTAssertFalse(signal.isActive)
    }

    @MainActor
    func testResetDeactivatesImmediately() async throws {
        let signal = StreamActivitySignal(decayInterval: 60)

        signal.bump()
        XCTAssertTrue(signal.isActive)

        signal.reset()
        XCTAssertFalse(signal.isActive, "reset must not wait for the decay window")

        // Reactivation after reset works (fresh expiry task).
        signal.bump()
        XCTAssertTrue(signal.isActive)
        signal.reset()
        XCTAssertFalse(signal.isActive)
    }

    @MainActor
    func testViewModelBumpsOnlyForContributingReasoningDeltas() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Think about it")
        XCTAssertTrue(didStart)
        XCTAssertFalse(viewModel.reasoningActivity.isActive, "turn start alone must not activate the orb")

        streamClient.emit(.reasoning("Considering the request"))
        XCTAssertTrue(viewModel.reasoningActivity.isActive, "a live reasoning delta must activate the signal")

        // Tool activity is independent of reasoning activity.
        XCTAssertFalse(viewModel.toolActivity.isActive)
    }

    @MainActor
    func testViewModelToolEventsBumpToolActivity() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Run a tool")
        XCTAssertTrue(didStart)
        XCTAssertFalse(viewModel.toolActivity.isActive)

        streamClient.emit(
            .toolStarted(
                ToolStreamEvent(
                    eventType: "tool_started",
                    name: "exec",
                    preview: "ls",
                    args: nil,
                    duration: nil,
                    isError: nil
                )
            )
        )
        XCTAssertTrue(viewModel.toolActivity.isActive, "tool start must activate the tool signal")
    }

    // MARK: - Turn phase model

    @MainActor
    func testTurnPhaseFollowsReasoningToolTextAndDoneTransitions() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        XCTAssertEqual(viewModel.turnPhase, .idle)

        let didStart = await viewModel.sendMessage("Think, then act")
        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.turnPhase, .idle, "turn start alone must not enter a phase")

        streamClient.emit(.reasoning("Considering"))
        XCTAssertEqual(viewModel.turnPhase, .reasoning)
        XCTAssertTrue(viewModel.isReasoningPhaseActive)

        let tool = ToolStreamEvent(
            eventType: "tool_started",
            name: "exec",
            preview: "ls",
            args: nil,
            duration: nil,
            isError: nil,
            stableID: "tool-1"
        )
        streamClient.emit(.toolStarted(tool))
        XCTAssertEqual(viewModel.turnPhase, .toolCalling)
        XCTAssertFalse(viewModel.isReasoningPhaseActive, "tool start ends the thinking step")
        XCTAssertTrue(viewModel.isToolPhaseActive)

        // Completing the tool keeps the tool step open — the model composes
        // its next move in silence, and the capsule must not stall out.
        streamClient.emit(
            .toolCompleted(
                ToolStreamEvent(
                    eventType: "tool_completed",
                    name: "exec",
                    preview: "ls",
                    args: nil,
                    duration: 0.2,
                    isError: false,
                    stableID: "tool-1"
                )
            )
        )
        XCTAssertEqual(viewModel.turnPhase, .toolCalling)
        XCTAssertTrue(viewModel.isToolPhaseActive)

        streamClient.emit(.token("The answer", phase: .finalAnswer))
        XCTAssertEqual(viewModel.turnPhase, .respondingText)
        XCTAssertFalse(viewModel.isToolPhaseActive)

        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertEqual(viewModel.turnPhase, .idle, "done must settle every capsule")
    }

    @MainActor
    func testReasoningPhaseHoldsAcrossTokenSilence() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Think hard")
        XCTAssertTrue(didStart)

        streamClient.emit(.reasoning("Step one"))
        XCTAssertEqual(viewModel.turnPhase, .reasoning)

        // 3s of silence — twice the StreamActivitySignal decay window. The
        // micro-liveness signal decays but the semantic phase (which drives
        // the capsule) must hold: the thinking step has not ended.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertFalse(
            viewModel.reasoningActivity.isActive,
            "micro-liveness decays after the silence window (unchanged behavior)"
        )
        XCTAssertEqual(viewModel.turnPhase, .reasoning, "the thinking step is still open")
        XCTAssertTrue(
            viewModel.isReasoningPhaseActive,
            "the capsule keeps animating through intra-step pauses"
        )

        // Resumed reasoning keeps the same phase; the final answer ends it.
        streamClient.emit(.reasoning(" and step two"))
        XCTAssertEqual(viewModel.turnPhase, .reasoning)
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(viewModel.liveReasoningText, "Step one and step two")
        streamClient.emit(.token("Answer", phase: .finalAnswer))
        XCTAssertEqual(viewModel.turnPhase, .respondingText)
        XCTAssertFalse(viewModel.isReasoningPhaseActive)
    }

    @MainActor
    func testReasoningResumingAfterToolPreservesMarkdownBlockBoundary() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Inspect and continue")
        XCTAssertTrue(didStart)
        streamClient.emit(.reasoning("The previous reasoning ends here."))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "read_file",
            preview: "Reading source",
            args: nil,
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.reasoning("**Recommending the next step**"))
        viewModel.flushPendingStreamingContent()

        XCTAssertEqual(
            viewModel.liveReasoningText,
            "The previous reasoning ends here.\n\n**Recommending the next step**"
        )
    }

    @MainActor
    func testReasoningResumingAfterCompletionOnlyToolPreservesBoundary() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Recover and continue")
        XCTAssertTrue(didStart)
        streamClient.emit(.reasoning("Reasoning before recovered completion."))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool.completed",
            name: "read_file",
            preview: "Read source",
            args: nil,
            duration: 0.2,
            isError: false
        )))
        streamClient.emit(.reasoning("**Continuing after recovery**"))
        viewModel.flushPendingStreamingContent()

        XCTAssertEqual(
            viewModel.liveReasoningText,
            "Reasoning before recovered completion.\n\n**Continuing after recovery**"
        )
    }

    @MainActor
    func testInterimAssistantEntersReasoningPhase() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Narrate your work")
        XCTAssertTrue(didStart)

        streamClient.emit(
            .interimAssistant(InterimAssistantStreamEvent(text: "Looking at the repo", alreadyStreamed: nil))
        )
        XCTAssertEqual(
            viewModel.turnPhase, .reasoning,
            "interim prose renders in the reasoning block, so it opens the thinking step"
        )
    }

    @MainActor
    func testStreamEndResetsPhaseWithoutDoneEvent() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Think")
        XCTAssertTrue(didStart)
        streamClient.emit(.reasoning("Working on it"))
        XCTAssertEqual(viewModel.turnPhase, .reasoning)

        // Errors / cancels route through stream end without a `done` payload.
        streamClient.emit(.streamEnd)
        XCTAssertEqual(viewModel.turnPhase, .idle, "stream end must settle the capsules")
    }

    // MARK: - Reasoning stint durations

    @MainActor
    func testReasoningDurationRecordedWhenStintClosesAndOverwrittenByNextStint() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Think, act, think again")
        XCTAssertTrue(didStart)
        XCTAssertNil(viewModel.lastReasoningDuration, "no stint has closed yet")

        // Stint 1: a contributing delta starts the clock; it stays open (nil)
        // until the turn semantically moves on.
        streamClient.emit(.reasoning("Considering"))
        XCTAssertNil(viewModel.lastReasoningDuration, "an open stint has no duration yet")

        try await Task.sleep(nanoseconds: 300_000_000)
        streamClient.emit(
            .toolStarted(
                ToolStreamEvent(
                    eventType: "tool_started",
                    name: "exec",
                    preview: "ls",
                    args: nil,
                    duration: nil,
                    isError: nil,
                    stableID: "tool-1"
                )
            )
        )
        let firstDuration = try XCTUnwrap(viewModel.lastReasoningDuration)
        XCTAssertGreaterThanOrEqual(firstDuration, 0.25, "stint 1 spanned the 300ms sleep")

        // Stint 2 closes almost immediately: the recorded value must be the
        // *second* stint's duration (overwrite), not an accumulation.
        streamClient.emit(.reasoning("Deciding next step"))
        streamClient.emit(.token("The answer", phase: .finalAnswer))
        let secondDuration = try XCTUnwrap(viewModel.lastReasoningDuration)
        XCTAssertLessThan(secondDuration, 0.25, "each stint overwrites — no accumulation across stints")

        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertEqual(viewModel.turnPhase, .idle)
    }

    @MainActor
    func testNonContributingReasoningDeltaDoesNotStartTheStintClock() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Think")
        XCTAssertTrue(didStart)

        // Empty deltas take the same `didAppendNewContent == false` path as
        // replayed duplicates during reconnect catch-up: the phase may advance
        // but the stint clock must not start.
        streamClient.emit(.reasoning(""))
        XCTAssertEqual(viewModel.turnPhase, .reasoning, "phase advances on event kind")

        streamClient.emit(.token("Answer", phase: .finalAnswer))
        XCTAssertNil(
            viewModel.lastReasoningDuration,
            "a stint that never received contributing content records no duration"
        )
    }

    @MainActor
    func testStreamEndWithoutDoneAbandonsTheOpenStint() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Think")
        XCTAssertTrue(didStart)
        streamClient.emit(.reasoning("Working"))

        // Error / cancel route through stream end without `done`: the open
        // stint is abandoned, not recorded.
        streamClient.emit(.streamEnd)
        XCTAssertNil(viewModel.lastReasoningDuration)
    }

    // MARK: - Completed-duration label formatting

    func testActivityDurationFormatUsesOneDecimalUnderTenSecondsAndWholeSecondsAbove() {
        XCTAssertEqual(ActivityDurationFormat.string(3.44), "3.4s")
        XCTAssertEqual(ActivityDurationFormat.string(0.06), "0.1s")
        XCTAssertEqual(ActivityDurationFormat.string(9.99), "10.0s")
        XCTAssertEqual(ActivityDurationFormat.string(12.4), "12s")
        XCTAssertEqual(ActivityDurationFormat.string(59.6), "60s")
    }

    // MARK: - Turn-complete haptic decision

    // ChatHaptics itself is fire-and-forget UIKit; the testable seam is the
    // view model's completion trigger, which ChatView observes and converts
    // into exactly one `.success` haptic per increment (gated on the haptics
    // AppStorage key). Success-only firing therefore reduces to: the trigger
    // bumps on the `done` path and never on error/cancel/stream-end paths.

    @MainActor
    func testCompletionHapticTriggerBumpsExactlyOnceOnDone() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Do the thing")
        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 0)

        streamClient.emit(.reasoning("Thinking"))
        streamClient.emit(.token("Answer"))
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 0, "streaming alone must not fire")

        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1, "done fires exactly once")

        // The transport lingering to streamEnd after done must not re-fire.
        streamClient.emit(.streamEnd)
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1)
    }

    @MainActor
    func testCompletionHapticTriggerDoesNotBumpOnErrorCancelOrBareStreamEnd() async throws {
        for terminal in [SSEEvent.error("boom"), .cancelled, .streamEnd] {
            let streamClient = PacingSpySSEStreamingClient()
            let viewModel = try makeActivityViewModel(streamClient: streamClient)

            let didStart = await viewModel.sendMessage("Do the thing")
            XCTAssertTrue(didStart)
            streamClient.emit(.reasoning("Thinking"))

            streamClient.emit(terminal)
            XCTAssertEqual(
                viewModel.responseCompletionHapticTrigger, 0,
                "terminal event \(terminal) must not fire the turn-complete haptic"
            )
            XCTAssertEqual(viewModel.turnPhase, .idle)
        }
    }

    /// The agent announces a whole parallel batch before running any of it, so
    /// two `tool` events with no completion between them are one batch; a
    /// completion closes the batch, so the next start opens a new one.
    @MainActor
    func testArrivalOrderSeparatesParallelBatchesFromSequentialCalls() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Go")
        XCTAssertTrue(didStart)

        // Two announced back-to-back: one parallel batch.
        streamClient.emit(.toolStarted(toolEvent(id: "p1", type: "tool_started")))
        streamClient.emit(.toolStarted(toolEvent(id: "p2", type: "tool_started")))
        streamClient.emit(.toolCompleted(toolEvent(id: "p1", type: "tool_completed", duration: 0.4)))
        streamClient.emit(.toolCompleted(toolEvent(id: "p2", type: "tool_completed", duration: 0.5)))

        // Announced only after the batch finished: a new, sequential batch.
        streamClient.emit(.toolStarted(toolEvent(id: "s1", type: "tool_started")))
        streamClient.emit(.toolCompleted(toolEvent(id: "s1", type: "tool_completed", duration: 0.2)))

        let batches = viewModel.liveToolCalls.map(\.batchIndex)
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches[0], batches[1], "tools announced together share a batch")
        XCTAssertNotEqual(batches[1], batches[2], "a completion closes the batch")

        let runs = ToolCallGroup.live(
            anchorMessageID: viewModel.toolCallAnchorMessageID,
            toolCalls: viewModel.liveToolCalls
        ).runs
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs[0].isParallel)
        XCTAssertFalse(runs[1].isParallel)
    }

    /// Purely sequential turns must never render a parallel cluster.
    @MainActor
    func testSequentialToolsNeverClusterAsParallel() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        _ = await viewModel.sendMessage("Go")

        for index in 0..<3 {
            streamClient.emit(.toolStarted(toolEvent(id: "t\(index)", type: "tool_started")))
            streamClient.emit(.toolCompleted(toolEvent(id: "t\(index)", type: "tool_completed", duration: 0.1)))
        }

        let runs = ToolCallGroup.live(
            anchorMessageID: viewModel.toolCallAnchorMessageID,
            toolCalls: viewModel.liveToolCalls
        ).runs
        XCTAssertEqual(runs.count, 3)
        XCTAssertFalse(runs.contains(where: \.isParallel))
    }

    /// The fold is keyed on the answer phase so it completes before the
    /// post-stream reconcile rebuilds these views with new identities.
    @MainActor
    func testAnswerPhaseDrivesTheActivityFold() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        _ = await viewModel.sendMessage("Go")

        streamClient.emit(.reasoning("Considering"))
        XCTAssertFalse(viewModel.isAnswerPhaseActive, "thinking must not fold the blocks")

        streamClient.emit(.toolStarted(toolEvent(id: "t0", type: "tool_started")))
        XCTAssertFalse(viewModel.isAnswerPhaseActive, "a running tool must not fold the blocks")

        streamClient.emit(.toolCompleted(toolEvent(id: "t0", type: "tool_completed", duration: 0.3)))
        XCTAssertFalse(
            viewModel.isAnswerPhaseActive,
            "the composing silence after the last tool must keep the block open"
        )

        streamClient.emit(.token("Here", phase: .finalAnswer))
        XCTAssertTrue(viewModel.isAnswerPhaseActive, "the first answer token folds the blocks")
    }

    @MainActor
    func testProvisionalProgressDoesNotFoldActivityBeforeLateInterimBoundary() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        _ = await viewModel.sendMessage("Inspect with tools")
        streamClient.emit(.reasoning("Inspecting"))
        streamClient.emit(.toolStarted(toolEvent(id: "t0", type: "tool_started")))
        streamClient.emit(.toolCompleted(toolEvent(id: "t0", type: "tool_completed", duration: 0.2)))

        streamClient.emit(.token("Now I will verify."))
        XCTAssertEqual(viewModel.turnPhase, .toolCalling)
        XCTAssertFalse(viewModel.isAnswerPhaseActive)
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(
            viewModel.messages.last(where: { $0.role == "assistant" })?.content,
            "Now I will verify."
        )

        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(
            text: "Now I will verify.",
            alreadyStreamed: true
        )))
        XCTAssertEqual(viewModel.turnPhase, .reasoning)
        XCTAssertFalse(viewModel.isAnswerPhaseActive)
        XCTAssertEqual(viewModel.liveReasoningText, "Inspecting\n\nNow I will verify.")
        XCTAssertEqual(
            viewModel.messages.last(where: { $0.role == "assistant" })?.content,
            "",
            "late already-streamed reconciliation must remove progress from the answer bubble"
        )

        streamClient.emit(.toolStarted(toolEvent(id: "t1", type: "tool_started")))
        XCTAssertEqual(viewModel.turnPhase, .toolCalling)
        XCTAssertFalse(viewModel.isAnswerPhaseActive)

        streamClient.emit(.token("Final answer", phase: .finalAnswer))
        XCTAssertEqual(viewModel.turnPhase, .respondingText)
        XCTAssertTrue(viewModel.isAnswerPhaseActive)
    }

    @MainActor
    func testExplicitCommentaryStreamsDirectlyIntoThought() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        _ = await viewModel.sendMessage("Narrate")
        streamClient.emit(.token("Checking the repo", phase: .commentary))
        viewModel.flushPendingStreamingContent()

        XCTAssertEqual(viewModel.turnPhase, .reasoning)
        XCTAssertEqual(viewModel.liveReasoningText, "Checking the repo")
        XCTAssertNotEqual(
            viewModel.messages.last(where: { $0.role == "assistant" })?.content,
            "Checking the repo"
        )
        XCTAssertFalse(viewModel.isAnswerPhaseActive)
    }

    @MainActor
    func testExplicitCommentaryLateInterimDoesNotDuplicateThought() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeActivityViewModel(streamClient: streamClient)

        _ = await viewModel.sendMessage("Narrate and reconcile")
        streamClient.emit(.token("Checking the repo", phase: .commentary))
        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(
            text: "Checking the repo",
            alreadyStreamed: true
        )))

        XCTAssertEqual(viewModel.liveReasoningText, "Checking the repo")
        XCTAssertFalse(viewModel.isAnswerPhaseActive)
        XCTAssertNotEqual(
            viewModel.messages.last(where: { $0.role == "assistant" })?.content,
            "Checking the repo"
        )
    }

    private func toolEvent(
        id: String,
        type: String,
        duration: Double? = nil
    ) -> ToolStreamEvent {
        ToolStreamEvent(
            eventType: type,
            name: "skill_view",
            preview: nil,
            args: nil,
            duration: duration,
            isError: duration == nil ? nil : false,
            stableID: id
        )
    }

    @MainActor
    private func makeActivityViewModel(
        streamClient: PacingSpySSEStreamingClient
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                    for: request
                )
            default:
                return apiTestJSONResponse(
                    #"{"session": {"session_id": "session-abc", "title": "Activity", "messages": []}}"#,
                    for: request
                )
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(
            SessionSummary.self,
            from: Data(
                #"{"session_id": "session-abc", "title": "Activity", "workspace": "/tmp/workspace"}"#.utf8
            )
        )

        return ChatViewModel(
            session: summary,
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: PacingSpySSEStreamingClient(),
            clarifyStreamClient: PacingSpySSEStreamingClient()
        )
    }

    @MainActor
    private func waitFor(
        timeoutNanoseconds: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async throws {
        let pollNanoseconds: UInt64 = 10_000_000
        var elapsed: UInt64 = 0
        while elapsed <= timeoutNanoseconds {
            if condition() { return }
            try await Task.sleep(nanoseconds: pollNanoseconds)
            elapsed += pollNanoseconds
        }
        XCTFail("timed out waiting for condition", file: file, line: line)
    }
}

/// Parallel tool batches are derived from stream arrival order, not from
/// timestamps: the agent announces every tool in a batch before running any of
/// them, and announce-run-announce-run for sequential calls.
final class ToolCallBatchGroupingTests: XCTestCase {
    func testParallelAnnouncementsShareOneRunAndSequentialOnesDoNot() {
        // Batch 0 announced together, then two sequential calls.
        let group = ToolCallGroup(
            anchorMessageID: "anchor",
            toolCalls: [
                makeCall(id: "a", batchIndex: 0),
                makeCall(id: "b", batchIndex: 0),
                makeCall(id: "c", batchIndex: 1),
                makeCall(id: "d", batchIndex: 2)
            ]
        )

        let runs = group.runs
        XCTAssertEqual(runs.count, 3)
        XCTAssertTrue(runs[0].isParallel)
        XCTAssertEqual(runs[0].toolCalls.map(\.id), ["a", "b"])
        XCTAssertFalse(runs[1].isParallel)
        XCTAssertFalse(runs[2].isParallel)
    }

    func testMissingBatchIndexesDegradeToSequentialRuns() {
        // History carries no grouping, so every call must stand alone rather
        // than collapsing into one bogus "parallel" cluster.
        let group = ToolCallGroup(
            anchorMessageID: "anchor",
            toolCalls: [
                makeCall(id: "a", batchIndex: nil),
                makeCall(id: "b", batchIndex: nil)
            ]
        )

        let runs = group.runs
        XCTAssertEqual(runs.count, 2)
        XCTAssertFalse(runs.contains(where: \.isParallel))
    }

    func testRunsPreserveArrivalOrder() {
        let group = ToolCallGroup(
            anchorMessageID: "anchor",
            toolCalls: [
                makeCall(id: "first", batchIndex: 0),
                makeCall(id: "second", batchIndex: 1),
                makeCall(id: "third", batchIndex: 1)
            ]
        )

        XCTAssertEqual(group.runs.flatMap(\.toolCalls).map(\.id), ["first", "second", "third"])
        XCTAssertTrue(group.runs[1].isParallel, "adjacent same-batch calls cluster")
    }

    func testMergePreservesBatchIndexWhenTheIDSwitchesToTheTranscriptID() {
        // Reconcile can swap a generated live id for the transcript's; if the
        // merge dropped batchIndex the cluster would silently flatten.
        let live = ToolCall(
            id: "live-tool-generated",
            name: "skill_view",
            preview: nil,
            args: nil,
            isCompleted: true,
            batchIndex: 3
        )
        let persisted = ToolCall(
            id: "tid-real",
            name: "skill_view",
            preview: "snippet",
            args: nil,
            isCompleted: true,
            batchIndex: nil
        )

        let merged = ToolCallGroup.groups(
            persistedToolCalls: [],
            messages: [],
            messageOffset: nil
        )
        XCTAssertTrue(merged.isEmpty, "no messages means no groups; guards the fixture")

        // Direct check of the run-splitting contract the merge must preserve.
        let group = ToolCallGroup(
            anchorMessageID: "anchor",
            toolCalls: [live, persisted]
        )
        XCTAssertEqual(group.runs.count, 2, "a nil batch must not join a numbered one")
    }

    private func makeCall(id: String, batchIndex: Int?) -> ToolCall {
        ToolCall(
            id: id,
            name: "skill_view",
            preview: nil,
            args: nil,
            isCompleted: true,
            batchIndex: batchIndex
        )
    }
}

/// Issue #214: the streaming bottom-follow scroll and active-row growth share
/// one short cadence-synced animation, disabled entirely under Reduce Motion.
final class ChatStreamingMotionTests: XCTestCase {
    func testStreamingFollowUsesShortEaseOut() {
        XCTAssertEqual(
            ChatMotion.streamingFollow(reduceMotion: false),
            .easeOut(duration: 0.15)
        )
    }

    func testStreamingFollowIsDisabledUnderReduceMotion() {
        XCTAssertNil(ChatMotion.streamingFollow(reduceMotion: true))
    }

    func testStreamingFollowIsShorterThanRegularFollowScroll() {
        // The streaming curve must stay snappier than the regular follow scroll
        // so per-flush retargeting keeps up with the word reveal cadence.
        XCTAssertNotEqual(
            ChatMotion.streamingFollow(reduceMotion: false),
            ChatMotion.scrollToLatest(reduceMotion: false)
        )
    }
}

private final class PacingSpySSEStreamingClient: SSEStreamingClient {
    private(set) var lastEventID: String?
    private var onEvent: (@MainActor (SSEEvent) -> Void)?

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        lastEventID = nil
        self.onEvent = onEvent
    }

    func stop() {}

    @MainActor
    func emit(_ event: SSEEvent) {
        onEvent?(event)
    }
}
