import Foundation
import Observation

struct HermesPlan: Equatable {
    struct Item: Identifiable, Equatable {
        let id: String
        let content: String
        let status: String
        var isDone: Bool { status == "completed" || status == "cancelled" }
    }

    static let itemLimit = 50

    let items: [Item]
    let revision: Int

    init?(_ json: BotJSON) {
        guard let rows = json["todos"].list else { return nil }
        let items: [Item] = rows.prefix(Self.itemLimit).enumerated().compactMap { index, row in
            guard let content = row["content"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
            let id = row["id"].text.flatMap { $0.isEmpty ? nil : $0 } ?? "plan-\(index)"
            return Item(id: id, content: content, status: row["status"].text ?? "pending")
        }
        guard !items.isEmpty else { return nil }
        self.items = items
        revision = max(0, json["revision"].integer ?? 0)
    }

    var completedCount: Int { items.filter(\.isDone).count }
    var current: Item? { items.first { $0.status == "in_progress" } ?? items.first { !$0.isDone } }
    var isFinished: Bool { items.allSatisfy(\.isDone) }

    var progress: String {
        let count = String(localized: "\(completedCount) of \(items.count)")
        guard let current else { return count }
        return "\(count) · \(current.content)"
    }

    var copyText: String {
        items.map { item in
            let marker = switch item.status {
            case "completed": "[x]"
            case "cancelled": "[-]"
            case "in_progress": "[~]"
            default: "[ ]"
            }
            return "\(marker) \(item.content)"
        }.joined(separator: "\n")
    }
}

struct HermesPlanState: Equatable {
    private(set) var plan: HermesPlan?
    private(set) var revision: Int?

    mutating func apply(_ json: BotJSON) -> Bool {
        guard let todos = json["todos"].list else { return false }
        let next = max(0, json["revision"].integer ?? 0)
        guard next >= (revision ?? 0) else { return false }
        let plan: HermesPlan?
        if todos.isEmpty {
            guard next >= 1 else { return false }
            plan = nil
        } else {
            guard let parsed = HermesPlan(json) else { return false }
            plan = parsed
        }
        guard plan != self.plan || next != revision else { return false }
        self.plan = plan
        revision = next
        return true
    }
}

@MainActor @Observable final class HermesChatActivity {
    struct SettledPlan: Equatable {
        let plan: HermesPlan
        let rowID: Int?
        let followsLastPrompt: Bool

        func afterRenderID(in rows: [TranscriptMessage]) -> String? {
            if let rowID, let row = rows.last(where: { $0.message.rowID == rowID }) { return row.renderID }
            guard followsLastPrompt, let prompt = rows.last(where: { $0.message.role == "user" && !$0.message.isSteerMessage }),
                  rowID == nil || prompt.message.rowID == nil else { return nil }
            return prompt.renderID
        }
    }

    struct RetryTarget: Equatable {
        let rowID: Int
        let text: String
        let showsPrompt: Bool
    }

    private struct PlanTurn: Equatable {
        let turn: Int
        var rowID: Int?
        let showsPrompt: Bool
    }

    let delegatedWork: HermesDelegatedWork

    init(wire: any BotTransport) {
        delegatedWork = HermesDelegatedWork(wire: wire)
    }

    private var planState = HermesPlanState()
    private var planTurn: PlanTurn?
    private var planRuntimeIsNew = false
    private var turn = 0
    private var isTurnRunning = false
    private var turnShowsPrompt = false
    private var turnPromptRowID: Int?

    private(set) var failure: HermesTurnOutcome?
    private(set) var notice: HermesTurnOutcome?
    private var failedPrompt: String?
    private var failedPromptRowID: Int?
    private var failedTurnStartedAt: Double?
    private var uncuttableRowID: Int?

    var plan: HermesPlan? { planState.plan }

    var pinnedPlan: HermesPlan? {
        guard isTurnRunning, let plan = planState.plan, planTurn?.turn == turn, !plan.isFinished else { return nil }
        return plan
    }

    var settledPlan: SettledPlan? {
        guard pinnedPlan == nil, let plan = planState.plan, let planTurn else { return nil }
        let followsLastPrompt = planTurn.turn == turn && planTurn.showsPrompt
        guard followsLastPrompt || planTurn.rowID != nil else { return nil }
        return SettledPlan(plan: plan, rowID: planTurn.rowID, followsLastPrompt: followsLastPrompt)
    }

    var retryTarget: RetryTarget? {
        guard failure?.offersRetry == true, let text = failedPrompt, let rowID = failedPromptRowID,
              rowID != uncuttableRowID else { return nil }
        return RetryTarget(rowID: rowID, text: text, showsPrompt: turnShowsPrompt && (turnPromptRowID ?? rowID) == rowID)
    }

    func turnDidStart(showsPrompt: Bool) {
        turn += 1
        isTurnRunning = true
        turnShowsPrompt = showsPrompt
        turnPromptRowID = nil
        failure = nil; notice = nil
        failedPrompt = nil; failedPromptRowID = nil; failedTurnStartedAt = nil
    }

    func turnDidEnd() {
        isTurnRunning = false
    }

    func receivePlan(_ json: BotJSON) {
        guard applyRevision(json) || json["revision"].integer.map({ max(0, $0) }) == planState.revision else { return }
        placePlan(inTurn: true)
    }

    private func applyRevision(_ json: BotJSON) -> Bool {
        var next = planState
        guard next.apply(json) else { return false }
        planState = next
        return true
    }

    private func placePlan(inTurn: Bool, promptRowID: Int? = nil) {
        if planState.plan == nil || !inTurn {
            if planTurn != nil { planTurn = nil }
        } else if planTurn?.turn != turn {
            planTurn = PlanTurn(turn: turn, rowID: promptRowID, showsPrompt: turnShowsPrompt)
        } else if let promptRowID, planTurn?.rowID != promptRowID {
            planTurn?.rowID = promptRowID
        }
    }

    func turnDidComplete(_ payload: BotJSON) {
        turnPromptRowID = payload["persisted_turn"]["user_row_id"].integer
        if let promptRowID = turnPromptRowID, planTurn?.turn == turn {
            planTurn?.rowID = promptRowID
        }
        let next = payload["status"].text == "error" ? HermesTurnOutcome(inflight: payload) : nil
        if next != failure { failure = next }
        failedPrompt = nil; failedPromptRowID = nil; failedTurnStartedAt = nil
        notice = HermesTurnOutcome(complete: payload)
    }

    func unseenTurnDidComplete() {
        turn += 1
        turnShowsPrompt = false
        turnPromptRowID = nil
        if failure != nil { failure = nil }
        if notice != nil { notice = nil }
        failedPrompt = nil; failedPromptRowID = nil; failedTurnStartedAt = nil
    }

    func readSnapshot(_ snapshot: BotJSON, promptRowID: Int?, followsTurn: Bool, followedPromptRowID: Int? = nil) {
        let inflight = snapshot["inflight"]
        let next = HermesTurnOutcome(inflight: inflight)
        if next != failure { failure = next }
        let startedAt = next == nil ? nil : inflight["started_at"].number
        failedPrompt = next == nil ? nil : inflight["user"].text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        failedPromptRowID = next == nil ? nil
            : promptRowID ?? (startedAt != nil && startedAt == failedTurnStartedAt ? failedPromptRowID : nil)
        failedTurnStartedAt = startedAt
        if applyRevision(snapshot["todo_state"]) {
            placePlan(inTurn: followsTurn && !planRuntimeIsNew, promptRowID: followedPromptRowID)
        } else if followsTurn, !planRuntimeIsNew, planTurn?.turn == turn {
            placePlan(inTurn: true, promptRowID: followedPromptRowID)
        }
        planRuntimeIsNew = false
    }

    func newestTurnWasUndone() {
        if planTurn?.turn == turn { planTurn = nil }
    }

    func dropPlan() {
        planState = HermesPlanState()
        planTurn = nil
        planRuntimeIsNew = true
    }

    func dropNotice() {
        if notice != nil { notice = nil }
    }

    func refuseRetry(at rowID: Int) {
        uncuttableRowID = rowID
    }
}
