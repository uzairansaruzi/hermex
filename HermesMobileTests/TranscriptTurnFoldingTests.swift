import XCTest
@testable import HermesMobile

final class TranscriptTurnFoldingTests: XCTestCase {
    private let firstTurnKey = TranscriptTurnClassifier.userTurnKey(absoluteIndex: 0)

    // MARK: - Settled vs active

    func testSettledTurnFoldsActivityBehindTheFinalReply() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 172.7, turnDuration: 72.3)
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1"])

        XCTAssertEqual(folds.folds.count, 1)
        let fold = folds.folds[0]
        XCTAssertEqual(fold.turnKey, firstTurnKey)
        XCTAssertEqual(fold.hostRenderID, "transcript:1")
        XCTAssertEqual(fold.label, .worked(elapsed: "1m 12s"))
        XCTAssertEqual(fold.label.title, "Worked for 1m 12s")

        XCTAssertNil(folds.rowState(for: "transcript:0", expandedTurnKeys: []))

        let hostState = folds.rowState(for: "transcript:1", expandedTurnKeys: [])
        XCTAssertEqual(hostState?.fold, fold)
        XCTAssertEqual(hostState?.hidesActivity, true)
        XCTAssertEqual(hostState?.hidesBubble, false)
        XCTAssertEqual(hostState?.isExpanded, false)

        let replyState = folds.rowState(for: "transcript:2", expandedTurnKeys: [])
        XCTAssertNil(replyState?.fold)
        XCTAssertEqual(replyState?.hidesBubble, false)
        XCTAssertEqual(replyState?.hidesActivity, false)
    }

    func testActiveTurnNeverFoldsWhileEarlierTurnsDo() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 160),
            user("u2", timestamp: 200),
            assistantWithTools("a3", timestamp: 205),
            assistant("a4", text: "Working on it.", timestamp: 210)
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1", "a3"], isStreamActive: true)

        XCTAssertEqual(folds.folds.map(\.turnKey), [firstTurnKey])
        XCTAssertNil(folds.rowState(for: "transcript:4", expandedTurnKeys: []))
    }

    func testTurnHoldingTheStreamingMessageNeverFolds() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Partial", timestamp: 110)
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1"], streamingAssistantMessageID: "a2")

        XCTAssertTrue(folds.folds.isEmpty)
    }

    // MARK: - Interruption and expansion

    func testStoppedTurnReadsYouStoppedAndOpensWhenExpanded() {
        let messages = [
            user("u1", timestamp: nil),
            assistantWithTools("a1", timestamp: nil),
            assistant("a2", text: "I was about to", timestamp: nil)
        ]
        let outcome = TranscriptTurnRunOutcome(
            turnKey: firstTurnKey,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 8.4),
            ending: .cancelled
        )

        let folds = derive(messages, activityAnchorIDs: ["a1"], outcome: outcome)

        XCTAssertEqual(folds.folds.first?.label, .stopped(elapsed: "8s"))
        XCTAssertEqual(folds.folds.first?.label.title, "You stopped after 8s")

        let expanded = folds.rowState(for: "transcript:1", expandedTurnKeys: [firstTurnKey])
        XCTAssertEqual(expanded?.isExpanded, true)
        XCTAssertEqual(expanded?.hidesActivity, false)
        XCTAssertNotNil(expanded?.fold, "The host row keeps its fold row while expanded")
    }

    func testOutcomeForAnotherTurnDoesNotRelabelThisOne() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 130)
        ]
        let outcome = TranscriptTurnRunOutcome(
            turnKey: TranscriptTurnClassifier.userTurnKey(absoluteIndex: 9),
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 3),
            ending: .cancelled
        )

        let folds = derive(messages, activityAnchorIDs: ["a1"], outcome: outcome)

        XCTAssertEqual(folds.folds.first?.label, .worked(elapsed: "30s"))
    }

    // MARK: - Elapsed sources

    func testMissingTimestampsFallBackToPlainWorked() {
        let messages = [
            user("u1", timestamp: nil),
            assistantWithTools("a1", timestamp: nil),
            assistant("a2", text: "Done.", timestamp: nil)
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1"])

        XCTAssertEqual(folds.folds.first?.label, .worked(elapsed: nil))
        XCTAssertEqual(folds.folds.first?.label.title, "Worked")
    }

    func testElapsedFallsBackToTheGapFromTheUserMessage() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 160)
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1"])

        XCTAssertEqual(folds.folds.first?.label, .worked(elapsed: "1m"))
    }

    func testServerTurnDurationWinsOverTheClientMeasuredRun() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 160, turnDuration: 45)
        ]
        let outcome = TranscriptTurnRunOutcome(
            turnKey: firstTurnKey,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 20),
            ending: .completed
        )

        let folds = derive(messages, activityAnchorIDs: ["a1"], outcome: outcome)

        XCTAssertEqual(folds.folds.first?.label, .worked(elapsed: "45s"))
    }

    func testTurnDurationDecodesFromUnderscoredKey() throws {
        let json = #"{"role":"assistant","content":"Done.","timestamp":172.7,"_turnDuration":72.863}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.turnDuration, 72.863)
    }

    // MARK: - Shape of the turn

    func testSingleReplyWithNothingToHideGetsNoFold() {
        let messages = [
            user("u1", timestamp: 100),
            assistant("a1", text: "Done.", timestamp: 110)
        ]

        XCTAssertTrue(derive(messages, activityAnchorIDs: []).folds.isEmpty)
    }

    func testSingleReplyWithReasoningFoldsOnlyTheReasoning() {
        let messages = [
            user("u1", timestamp: 100),
            assistant("a1", text: "Done.", timestamp: 110, reasoning: "Thinking it through")
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1"])

        XCTAssertEqual(folds.folds.first?.hostRenderID, "transcript:1")
        let state = folds.rowState(for: "transcript:1", expandedTurnKeys: [])
        XCTAssertNotNil(state?.fold)
        XCTAssertEqual(state?.hidesActivity, true)
        XCTAssertEqual(state?.hidesBubble, false)
    }

    func testHiddenActivityDoesNotCountWhenCardsAreOff() {
        let messages = [
            user("u1", timestamp: 100),
            assistant("a1", text: "Done.", timestamp: 110, reasoning: "Thinking it through")
        ]

        XCTAssertTrue(derive(messages, activityAnchorIDs: []).folds.isEmpty)
    }

    func testInterimRepliesFoldBetweenFirstAndLast() {
        let messages = [
            user("u1", timestamp: 100),
            assistant("a1", text: "Looking.", timestamp: 105),
            assistant("a2", text: "Still looking.", timestamp: 110),
            assistant("a3", text: "Done.", timestamp: 120)
        ]

        let folds = derive(messages, activityAnchorIDs: [])

        XCTAssertEqual(folds.folds.first?.hostRenderID, "transcript:2")
        XCTAssertEqual(folds.rowState(for: "transcript:1", expandedTurnKeys: [])?.hidesBubble, false)
        XCTAssertEqual(folds.rowState(for: "transcript:2", expandedTurnKeys: [])?.hidesBubble, true)
        XCTAssertEqual(folds.rowState(for: "transcript:3", expandedTurnKeys: [])?.hidesBubble, false)
    }

    func testTurnKeysUseAbsoluteIndicesAcrossPagedOffsets() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 130)
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1"], messageOffset: 40)

        XCTAssertEqual(folds.folds.first?.turnKey, TranscriptTurnClassifier.userTurnKey(absoluteIndex: 40))
        XCTAssertEqual(folds.folds.first?.hostRenderID, "transcript:41")
    }

    // MARK: - Helpers

    private func derive(
        _ messages: [ChatMessage],
        activityAnchorIDs: Set<String>,
        messageOffset: Int? = nil,
        isStreamActive: Bool = false,
        streamingAssistantMessageID: String? = nil,
        outcome: TranscriptTurnRunOutcome? = nil
    ) -> TranscriptTurnFolds {
        let transcript = ChatViewModel.transcriptMessages(
            from: messages,
            messageOffset: messageOffset,
            renderedActivityAnchorIDs: activityAnchorIDs
        )
        return TranscriptTurnFolds.derive(
            transcriptMessages: transcript,
            messages: messages,
            messageOffset: messageOffset,
            activityAnchorIDs: activityAnchorIDs,
            rendersBubble: { $0.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false },
            isStreamActive: isStreamActive,
            streamingAssistantMessageID: streamingAssistantMessageID,
            latestRunOutcome: outcome
        )
    }

    private func user(_ id: String, timestamp: Double?) -> ChatMessage {
        ChatMessage(role: "user", content: "Do the thing", timestamp: timestamp, messageId: id)
    }

    private func assistant(
        _ id: String,
        text: String?,
        timestamp: Double?,
        reasoning: String? = nil,
        turnDuration: Double? = nil
    ) -> ChatMessage {
        ChatMessage(
            role: "assistant",
            content: text,
            timestamp: timestamp,
            messageId: id,
            reasoning: reasoning,
            turnDuration: turnDuration
        )
    }

    private func assistantWithTools(_ id: String, timestamp: Double?) -> ChatMessage {
        ChatMessage(
            role: "assistant",
            content: "",
            timestamp: timestamp,
            messageId: id,
            toolCalls: [.object(["id": .string("call-\(id)"), "function": .object(["name": .string("terminal")])])]
        )
    }
}
