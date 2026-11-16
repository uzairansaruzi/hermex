import SwiftUI
import XCTest
@testable import HermesMobile

/// Reveal tests for #1126: each tick shows streamed text up to the last
/// whitespace, a held fragment shows on the next tick, and completion paths
/// flush everything at once. Ticks are driven by hand; nothing sleeps.
final class ChatViewModelStreamingPaceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testHeldFragmentShowsOnTheNextTick() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let ticks = ManualRevealTicks()
        let viewModel = try makeViewModel(streamClient: streamClient, revealTick: ticks.tick)

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("alpha beta gam"))
        await waitForTickRequest(ticks, 1)
        ticks.fire()
        let firstTick = await nextAssistantContent(of: viewModel)
        XCTAssertEqual(firstTick, "alpha beta ")

        // The held fragment re-arms a tick; text arriving meanwhile rides it.
        await waitForTickRequest(ticks, 2)
        streamClient.emit(.token("ma"))
        ticks.fire()
        let secondTick = await nextAssistantContent(of: viewModel) { $0 != "alpha beta " }
        XCTAssertEqual(secondTick, "alpha beta gamma", "a fragment is held for one tick only")

        // Tokens after the buffer emptied schedule a fresh tick.
        streamClient.emit(.token(" delta "))
        await waitForTickRequest(ticks, 3)
        ticks.fire()
        let thirdTick = await nextAssistantContent(of: viewModel) { $0 != "alpha beta gamma" }
        XCTAssertEqual(thirdTick, "alpha beta gamma delta ")
    }

    @MainActor
    func testTextWithoutWhitespaceStreamsOneTickBehind() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let ticks = ManualRevealTicks()
        let viewModel = try makeViewModel(streamClient: streamClient, revealTick: ticks.tick)

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("你好世界"))
        await waitForTickRequest(ticks, 1)
        ticks.fire()
        // The tick held the whole fragment and asked for the next one.
        await waitForTickRequest(ticks, 2)
        XCTAssertEqual(assistantContent(of: viewModel) ?? "", "")

        ticks.fire()
        let released = await nextAssistantContent(of: viewModel)
        XCTAssertEqual(released, "你好世界")
    }

    @MainActor
    func testCompletionFlushesTheHeldFragmentImmediately() async throws {
        for completion in [SSEEvent.done(DoneStreamEvent()), .cancelled] {
            let streamClient = PacingSpySSEStreamingClient()
            let ticks = ManualRevealTicks()
            let viewModel = try makeViewModel(streamClient: streamClient, revealTick: ticks.tick)

            let didStart = await viewModel.sendMessage("Stream a reply")
            XCTAssertTrue(didStart)

            streamClient.emit(.token("alpha beta gam"))
            await waitForTickRequest(ticks, 1)
            ticks.fire()
            let firstTick = await nextAssistantContent(of: viewModel)
            XCTAssertEqual(firstTick, "alpha beta ")

            // The held fragment had re-armed tick 2; completion cancels it.
            await waitForTickRequest(ticks, 2)
            streamClient.emit(completion)
            XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gam", "\(completion)")

            // The cancelled tick returning late shows nothing and asks for no more.
            ticks.release(2)
            await waitForTickReturn(ticks, 2)
            XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gam", "\(completion)")
            XCTAssertEqual(ticks.requestCount, 2, "\(completion)")
        }
    }

    @MainActor
    func testCancelledTickReturningLateLeavesTheNewerTickInCharge() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let ticks = ManualRevealTicks()
        let viewModel = try makeViewModel(streamClient: streamClient, revealTick: ticks.tick)

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("alpha beta gam"))
        await waitForTickRequest(ticks, 1)
        ticks.release(1)
        let firstTick = await nextAssistantContent(of: viewModel)
        XCTAssertEqual(firstTick, "alpha beta ")

        // A mid-stream flush (interim reply, snapshot save) cancels tick 2, and
        // the next tokens schedule tick 3 while tick 2 is still suspended.
        await waitForTickRequest(ticks, 2)
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gam")
        streamClient.emit(.token(" delta eps"))
        await waitForTickRequest(ticks, 3)

        // Tick 2 returns late: it must neither reveal text nor free tick 3's slot.
        ticks.release(2)
        await waitForTickReturn(ticks, 2)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gam")
        XCTAssertEqual(ticks.requestCount, 3, "a stale tick must not schedule another")

        ticks.release(3)
        let thirdTick = await nextAssistantContent(of: viewModel) { $0 != "alpha beta gam" }
        XCTAssertEqual(thirdTick, "alpha beta gam delta ")

        await waitForTickRequest(ticks, 4)
        ticks.release(4)
        let fourthTick = await nextAssistantContent(of: viewModel) { $0 != "alpha beta gam delta " }
        XCTAssertEqual(fourthTick, "alpha beta gam delta eps")
        await waitForTickReturn(ticks, 4)
        XCTAssertEqual(ticks.requestCount, 4, "the emptied buffer must not re-arm a tick")
    }

    @MainActor
    func testGatedContentConvergesByteIdenticalToTheJoin() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let ticks = ManualRevealTicks()
        let viewModel = try makeViewModel(streamClient: streamClient, revealTick: ticks.tick)

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

        await waitForTickRequest(ticks, 1)
        ticks.fire()
        await waitForTickRequest(ticks, 2)
        ticks.fire()

        let target = chunks.joined()
        let converged = await nextAssistantContent(of: viewModel) { $0 == target }
        let content = try XCTUnwrap(converged)
        XCTAssertEqual(
            Array(content.utf8),
            Array(target.utf8),
            "gated content must converge byte-identical to the concatenation"
        )
    }

    @MainActor
    func testLargeNormalStreamConvergesByteIdenticalWithoutReplayState() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let ticks = ManualRevealTicks()
        let viewModel = try makeViewModel(streamClient: streamClient, revealTick: ticks.tick)

        let didStart = await viewModel.sendMessage("Stream a long reply")
        XCTAssertTrue(didStart)

        let chunks = (0..<160).map { index in
            "## Section \(index)\n\n"
                + String(
                    repeating: "stable markdown text with **formatting** and `code`. ",
                    count: 10
                )
                + "\n"
        }
        let reasoningChunks = (0..<32).map { "reasoning-\($0) " }
        for chunk in reasoningChunks {
            streamClient.emit(.reasoning(chunk))
        }
        for chunk in chunks {
            streamClient.emit(.token(chunk))
        }

        // The text ends in whitespace, so one tick shows all of it.
        await waitForTickRequest(ticks, 1)
        ticks.fire()

        let target = chunks.joined()
        let shown = await nextAssistantContent(of: viewModel)
        let content = try XCTUnwrap(shown)
        XCTAssertEqual(
            Array(content.utf8),
            Array(target.utf8),
            "a large normal stream must preserve every byte without replay de-duplication"
        )
        XCTAssertEqual(
            viewModel.liveReasoningText,
            reasoningChunks.joined(),
            "normal reasoning events must preserve every byte without replay de-duplication"
        )
    }

    /// #1417: a text-only tick patches the reply's row instead of re-deriving the transcript,
    /// and the transcript still matches a from-scratch derivation, through cancellation too.
    @MainActor
    func testTextOnlyTicksPatchTheReplyWithoutReDerivingTheTranscript() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let ticks = ManualRevealTicks()
        let viewModel = try makeViewModel(streamClient: streamClient, revealTick: ticks.tick, history: Self.settledTurns(3))
        await viewModel.loadMessages()

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("alpha "))
        await waitForTickRequest(ticks, 1)
        ticks.fire()
        _ = await nextAssistantContent(of: viewModel)
        let revision = viewModel.transcriptStructureRevision

        for (offset, word) in ["beta ", "gamma ", "delta "].enumerated() {
            streamClient.emit(.token(word))
            await waitForTickRequest(ticks, offset + 2)
            ticks.fire()
            _ = await nextAssistantContent(of: viewModel) { $0.hasSuffix(word) }
            assertTranscriptMatchesFromScratch(viewModel)
        }
        XCTAssertEqual(viewModel.transcriptStructureRevision, revision, "A text-only tick must not re-derive the transcript")

        streamClient.emit(.token("epsil"))
        await waitForTickRequest(ticks, 5)
        streamClient.emit(.cancelled)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma delta epsil")
        assertTranscriptMatchesFromScratch(viewModel)
    }

    /// #1417: reasoning reads the reply's text, so a tick that completes an in-text
    /// `<think>` block re-derives the transcript and shows the reasoning card.
    @MainActor
    func testATickThatCompletesInTextReasoningReDerivesTheTranscript() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let ticks = ManualRevealTicks()
        let viewModel = try makeViewModel(streamClient: streamClient, revealTick: ticks.tick, history: Self.settledTurns(2))
        await viewModel.loadMessages()

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("<think>Plan "))
        await waitForTickRequest(ticks, 1)
        ticks.fire()
        _ = await nextAssistantContent(of: viewModel)
        XCTAssertTrue(viewModel.displayedReasoningGroups.isEmpty, "An open block is not reasoning yet")

        streamClient.emit(.token("the answer.</think> Hello "))
        await waitForTickRequest(ticks, 2)
        ticks.fire()
        _ = await nextAssistantContent(of: viewModel) { $0.hasSuffix("Hello ") }
        XCTAssertEqual(viewModel.displayedReasoningGroups.map(\.text), ["Plan the answer."])
        assertTranscriptMatchesFromScratch(viewModel)
    }

    // MARK: - Helpers

    /// `count` settled prompt/reply turns, as a webui session's `messages` JSON.
    private static func settledTurns(_ count: Int) -> String {
        let turns = (0..<count).map { index in
            #"{"role": "user", "content": "Question \#(index)", "timestamp": \#(1_770_000_000 + index * 10), "message_id": "user-\#(index)"}, "#
                + #"{"role": "assistant", "content": "Answer \#(index)", "timestamp": \#(1_770_000_005 + index * 10), "message_id": "assistant-\#(index)"}"#
        }
        return "[" + turns.joined(separator: ", ") + "]"
    }

    /// The presented rows and reasoning cards equal a from-scratch derivation of `messages`.
    @MainActor
    private func assertTranscriptMatchesFromScratch(
        _ viewModel: ChatViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reasoningGroups = ChatViewModel.reasoningDisplayGroups(
            messages: viewModel.messages,
            messageOffset: viewModel.messagesOffset,
            archivedGroups: viewModel.completedReasoningGroups
        )
        XCTAssertEqual(viewModel.displayedReasoningGroups, reasoningGroups, file: file, line: line)
        let transcript = ChatViewModel.transcriptMessages(
            from: viewModel.messages,
            messageOffset: viewModel.messagesOffset,
            preservingEmptyAssistantID: viewModel.streamingAssistantMessageID,
            renderedActivityAnchorIDs: Set(reasoningGroups.compactMap(\.anchorMessageID))
                .union(viewModel.completedToolCallGroups.compactMap(\.anchorMessageID))
        )
        XCTAssertEqual(viewModel.displayedTranscriptMessages, transcript, file: file, line: line)
    }

    @MainActor
    private func makeViewModel(
        streamClient: PacingSpySSEStreamingClient,
        revealTick: @escaping @Sendable () async throws -> Void,
        history: String = "[]"
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
                    #"{"session": {"session_id": "session-abc", "title": "Pacing", "messages": "# + history + "}}",
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
            streamingRevealTick: revealTick
        )
    }

    @MainActor
    private func waitForTickRequest(
        _ ticks: ManualRevealTicks,
        _ number: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let requested = ticks.expectRequest(number)
        guard await XCTWaiter().fulfillment(of: [requested], timeout: 5) == .completed else {
            return XCTFail("Reveal tick \(number) was never requested", file: file, line: line)
        }
    }

    @MainActor
    private func waitForTickReturn(
        _ ticks: ManualRevealTicks,
        _ number: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let returned = ticks.expectReturn(number)
        guard await XCTWaiter().fulfillment(of: [returned], timeout: 5) == .completed else {
            return XCTFail("Reveal tick \(number) never returned", file: file, line: line)
        }
    }

    @MainActor
    private func assistantContent(of viewModel: ChatViewModel) -> String? {
        viewModel.messages.last(where: { $0.role == "assistant" })?.content
    }

    /// Waits on observation, not a poll, for the first assistant content
    /// matching `predicate`, and returns it.
    @MainActor
    private func nextAssistantContent(
        of viewModel: ChatViewModel,
        file: StaticString = #filePath,
        line: UInt = #line,
        where predicate: (String) -> Bool = { !$0.isEmpty }
    ) async -> String? {
        while true {
            if let content = assistantContent(of: viewModel), !content.isEmpty, predicate(content) {
                return content
            }
            let changed = XCTestExpectation(description: "assistant content changed")
            withObservationTracking { _ = viewModel.messages } onChange: { changed.fulfill() }
            guard await XCTWaiter().fulfillment(of: [changed], timeout: 5) == .completed else {
                XCTFail("Assistant content never matched", file: file, line: line)
                return assistantContent(of: viewModel)
            }
        }
    }
}

/// Hands each reveal tick to the test, which releases it with `fire()` or
/// `release(_:)`. The tick is main-actor isolated, so the view model's code
/// after it runs in the same main-actor job that marks the tick returned.
@MainActor
final class ManualRevealTicks {
    private var inFlight: [Int: CheckedContinuation<Void, Never>] = [:]
    private var requestExpectations: [Int: XCTestExpectation] = [:]
    private var returnExpectations: [Int: XCTestExpectation] = [:]
    private var returned: Set<Int> = []
    private(set) var requestCount = 0

    var tick: @Sendable () async throws -> Void {
        { @MainActor [weak self] in await self?.wait() }
    }

    /// Fulfilled once the view model has asked for its `number`th tick.
    func expectRequest(_ number: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "reveal tick \(number) requested")
        if requestCount >= number {
            expectation.fulfill()
        } else {
            requestExpectations[number] = expectation
        }
        return expectation
    }

    /// Fulfilled once the `number`th tick has returned to the view model.
    func expectReturn(_ number: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "reveal tick \(number) returned")
        if returned.contains(number) {
            expectation.fulfill()
        } else {
            returnExpectations[number] = expectation
        }
        return expectation
    }

    /// Releases every tick in flight, oldest first.
    func fire() {
        inFlight.keys.sorted().forEach(release)
    }

    /// Releases the `number`th tick, even one its view model already cancelled.
    func release(_ number: Int) {
        inFlight.removeValue(forKey: number)?.resume()
    }

    private func wait() async {
        let number = requestCount + 1
        await withCheckedContinuation { continuation in
            inFlight[number] = continuation
            requestCount = number
            requestExpectations.removeValue(forKey: number)?.fulfill()
        }
        returned.insert(number)
        returnExpectations.removeValue(forKey: number)?.fulfill()
    }
}

final class PacingSpySSEStreamingClient: SSEStreamingClient {
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
