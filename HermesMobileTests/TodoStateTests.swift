import XCTest
@testable import HermesMobile

/// Contract tests for the `todo_state` snapshot.
///
/// The shapes here are taken from `api/todo_state.py` in the pinned upstream:
/// `_normalize_snapshot` guarantees only that `todos` is a list, so every other
/// field has to survive being absent or malformed.
final class TodoStateTests: XCTestCase {
    private func decode(_ json: String) throws -> TodoState {
        try JSONDecoder().decode(TodoState.self, from: Data(json.utf8))
    }

    func testDecodesCanonicalSnapshot() throws {
        let state = try decode("""
        {"todos":[{"id":"1","content":"Review","status":"completed"},
                  {"id":"2","content":"Build","status":"in_progress"},
                  {"id":"3","content":"Ship","status":"pending"}],
         "summary":{"total":3,"pending":1,"in_progress":1,"completed":1,"cancelled":0},
         "version":1,"ts":1000.5,"session_id":"abc"}
        """)

        XCTAssertEqual(state.todos.count, 3)
        XCTAssertEqual(state.todos[1].status, .inProgress)
        XCTAssertEqual(state.summary.total, 3)
        XCTAssertEqual(state.version, 1)
        XCTAssertEqual(state.ts, 1000.5)
        XCTAssertEqual(state.sessionID, "abc")
    }

    /// Upstream explicitly documents that `todos: []` is a *valid* snapshot
    /// meaning the plan was cleared — not missing data. Guarding on non-empty
    /// was a real bug there that made the panel disagree with the agent.
    func testEmptyListIsAValidSnapshot() throws {
        let state = try decode(#"{"todos":[],"summary":{}}"#)
        XCTAssertTrue(state.isEmpty)
        XCTAssertEqual(state.summary.total, 0)
    }

    func testUnknownStatusFallsBackToPending() throws {
        let state = try decode(#"{"todos":[{"id":"1","content":"X","status":"deferred"}]}"#)
        XCTAssertEqual(state.todos.first?.status, .pending)
    }

    func testFallsBackToTextWhenContentAbsent() throws {
        let state = try decode(#"{"todos":[{"id":"1","text":"From text","status":"pending"}]}"#)
        XCTAssertEqual(state.todos.first?.content, "From text")
    }

    func testIntegerIDsDecodeLossily() throws {
        let state = try decode(#"{"todos":[{"id":7,"content":"Numeric id","status":"pending"}]}"#)
        XCTAssertEqual(state.todos.first?.id, "7")
    }

    /// A malformed/absent summary normalizes to `{}` upstream; recounting keeps
    /// the pill from reading "0 of 0" over a populated list.
    func testRecountsWhenSummaryMissing() throws {
        let state = try decode("""
        {"todos":[{"id":"1","content":"A","status":"completed"},
                  {"id":"2","content":"B","status":"pending"}]}
        """)
        XCTAssertEqual(state.summary.total, 2)
        XCTAssertEqual(state.summary.completed, 1)
        XCTAssertEqual(state.summary.pending, 1)
    }

    func testCurrentStepTracksInProgressRow() {
        let state = TodoState(todos: [
            TodoItem(rawID: "1", content: "A", status: .completed),
            TodoItem(rawID: "2", content: "B", status: .completed),
            TodoItem(rawID: "3", content: "C", status: .inProgress),
            TodoItem(rawID: "4", content: "D", status: .pending)
        ])
        XCTAssertEqual(state.currentStep, 3)
        XCTAssertFalse(state.isFinished)
    }

    func testFinishedWhenAllResolved() {
        let state = TodoState(todos: [
            TodoItem(rawID: "1", content: "A", status: .completed),
            TodoItem(rawID: "2", content: "B", status: .cancelled)
        ])
        XCTAssertTrue(state.isFinished)
        XCTAssertEqual(state.currentStep, 2)
    }

    // MARK: - Recency

    func testNewerTimestampSupersedes() {
        let old = TodoState(todos: [], ts: 100)
        let new = TodoState(todos: [], ts: 200)
        XCTAssertTrue(new.supersedes(old))
        XCTAssertFalse(old.supersedes(new))
    }

    /// A todo message can lose its timestamp during context compaction, which
    /// is exactly the case where upstream's zero-default let a stale in-flight
    /// snapshot beat a fresh cold-load one. Missing timestamps must not lose.
    func testMissingTimestampDoesNotLoseToTimestampedSnapshot() {
        let timestamped = TodoState(todos: [], ts: 5000)
        let untimestamped = TodoState(todos: [], ts: nil)
        XCTAssertTrue(untimestamped.supersedes(timestamped))
    }

    func testAnySnapshotSupersedesNil() {
        XCTAssertTrue(TodoState(todos: []).supersedes(nil))
    }

    // MARK: - Malformed elements

    /// A single bad element must not collapse the list. Empty is a valid
    /// "cleared" snapshot, so an all-or-nothing decode would supersede the real
    /// plan and blank the pill rather than being ignored.
    func testMalformedElementDoesNotEraseTheRest() throws {
        let state = try decode("""
        {"todos":[{"id":"1","content":"Keep me","status":"completed"},
                  "not-an-object",
                  {"id":"3","content":"Keep me too","status":"pending"}]}
        """)
        XCTAssertEqual(state.todos.count, 2)
        XCTAssertEqual(state.todos.first?.content, "Keep me")
        XCTAssertEqual(state.todos.last?.content, "Keep me too")
    }

    func testAllCancelledIsFinishedButNotSuccessful() {
        let state = TodoState(todos: [
            TodoItem(rawID: "1", content: "A", status: .cancelled),
            TodoItem(rawID: "2", content: "B", status: .cancelled)
        ])
        XCTAssertTrue(state.isFinished)
        XCTAssertTrue(state.hasCancelledWork)
    }

    func testCompletedPlanHasNoCancelledWork() {
        let state = TodoState(todos: [
            TodoItem(rawID: "1", content: "A", status: .completed)
        ])
        XCTAssertTrue(state.isFinished)
        XCTAssertFalse(state.hasCancelledWork)
    }

    // MARK: - Plan window layout

    func testPlanWindowShowsAtMostFiveMeasuredRows() {
        let height = PlanTimelineLayout.windowHeight(
            rowHeights: Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, CGFloat(44)) }),
            todoCount: 8,
            availableHeight: 1_000
        )

        XCTAssertEqual(PlanTimelineLayout.maximumVisibleRows, 5)
        XCTAssertEqual(height, 5 * 44 + PlanTimelineLayout.topChrome)
    }

    func testPlanWindowUsesNaturalHeightForShortPlan() {
        let height = PlanTimelineLayout.windowHeight(
            rowHeights: [0: 44, 1: 60, 2: 44],
            todoCount: 3,
            availableHeight: 1_000
        )

        XCTAssertEqual(height, 148 + PlanTimelineLayout.verticalChrome)
    }

    func testExpandedTaskStillRespectsAvailableDockHeight() {
        let height = PlanTimelineLayout.windowHeight(
            rowHeights: [0: 500, 1: 44, 2: 44, 3: 44, 4: 44],
            todoCount: 5,
            availableHeight: 400
        )

        XCTAssertEqual(height, 200)
    }

    func testPlanWindowUsesBoundedEstimateBeforeMeasurement() {
        let height = PlanTimelineLayout.windowHeight(
            rowHeights: [:],
            todoCount: 20,
            availableHeight: 300
        )

        XCTAssertEqual(height, 150)
    }

    // MARK: - Transport

    func testSSEDecodesTodoStateEvent() {
        let event = SSEEventDecoder.decode(
            eventType: "todo_state",
            data: #"{"todos":[{"id":"1","content":"A","status":"pending"}],"session_id":"s1"}"#
        )
        guard case .todoState(let payload) = event else {
            return XCTFail("Expected .todoState, got \(event)")
        }
        XCTAssertEqual(payload.todos.count, 1)
        XCTAssertEqual(payload.sessionID, "s1")
    }

    func testSSEIgnoresMalformedTodoState() {
        let event = SSEEventDecoder.decode(eventType: "todo_state", data: "not json")
        XCTAssertEqual(event, .ignored)
    }

    func testSessionDetailCarriesColdLoadSidecar() throws {
        let detail = try JSONDecoder().decode(SessionDetail.self, from: Data("""
        {"session_id":"s1","title":"T",
         "todo_state":{"todos":[{"id":"1","content":"Cold","status":"completed"}],"ts":42}}
        """.utf8))
        XCTAssertEqual(detail.todoState?.todos.first?.content, "Cold")
        XCTAssertEqual(detail.todoState?.ts, 42)
    }

    func testSessionDetailWithoutSidecarIsNil() throws {
        let detail = try JSONDecoder().decode(SessionDetail.self, from: Data(
            #"{"session_id":"s1","title":"T"}"#.utf8
        ))
        XCTAssertNil(detail.todoState)
    }
}
