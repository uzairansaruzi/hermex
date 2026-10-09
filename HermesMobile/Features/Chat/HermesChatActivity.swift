import Foundation
import Observation

/// The agent's plan, from `todo.updated` and a snapshot's `todo_state`
/// (`tui_gateway/tool_progress.py`): `{todos: [{id, content, status}], revision}`.
struct HermesPlan: Equatable {
    struct Item: Identifiable, Equatable {
        let id: String
        let content: String
        /// `pending`, `in_progress`, `completed` or `cancelled`; anything else reads as pending.
        let status: String
        var isDone: Bool { status == "completed" || status == "cancelled" }
    }

    static let itemLimit = 50

    let items: [Item]
    let revision: Int

    /// `nil` when the payload is malformed or carries no items.
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

    /// "2 of 5 · current step", as the plan row and strip show it.
    var progress: String {
        let count = String(localized: "\(completedCount) of \(items.count)")
        guard let current else { return count }
        return "\(count) · \(current.content)"
    }

    /// The list as copied text, one `[x]`-style marker per item.
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

/// The newest plan a session's host reported, for every Hermes chat and Bot Chat.
/// Revision-monotonic: an older revision never replaces a newer one. An empty list at
/// revision 1 or later is the host clearing the plan (`_normalize_todo_state`), which hides
/// it until a newer revision.
struct HermesPlanState: Equatable {
    private(set) var plan: HermesPlan?
    /// The newest revision applied, a clear included; nil before any.
    private(set) var revision: Int?

    /// Applies a `todo.updated` payload or a snapshot's `todo_state`. False when it changed
    /// nothing: malformed, older than the revision held, or the same plan again.
    mutating func apply(_ json: BotJSON) -> Bool {
        guard let todos = json["todos"].list else { return false }
        let next = max(0, json["revision"].integer ?? 0)
        guard next >= (revision ?? 0) else { return false }
        let plan: HermesPlan?
        if todos.isEmpty {
            // An unused store reports an empty list at revision 0: no plan, and no clear.
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

/// A Hermes chat's plan and how its last turn ended (#1139). `HermesChatTurnCoordinator` owns
/// it and only forwards its frames and snapshots here; `ChatView` draws the plan pinned above
/// the composer while its turn runs (`pinnedPlan`), then at the top of that turn
/// (`settledPlan`), and the outcome row under the failed or warned turn. Never cached.
@MainActor @Observable final class HermesChatActivity {
    /// A plan out of the strip, at the top of its turn: after that turn's prompt.
    struct SettledPlan: Equatable {
        let plan: HermesPlan
        /// The host's row for the turn's prompt, once `message.complete` named it.
        let rowID: Int?
        /// The plan's turn is the newest one, so its prompt is the transcript's last.
        let isInNewestTurn: Bool
    }

    /// What Retry resends, the host's raw `inflight.user`, cut before the failed prompt's row.
    struct RetryTarget: Equatable {
        let rowID: Int
        let text: String
    }

    /// The turn a plan was last revised in, counted by `turnDidStart`, and its prompt's row.
    private struct PlanTurn: Equatable {
        let turn: Int
        var rowID: Int?
    }

    private var planState = HermesPlanState()
    private var planTurn: PlanTurn?
    private var turn = 0
    private var isTurnRunning = false

    /// The failure the host retained for the last turn: from its `message.complete`, then from
    /// every snapshot's `inflight`, so a reattach rebuilds the same row. Nil after a success
    /// or a Stop, and once the next turn starts.
    private(set) var failure: HermesTurnOutcome?
    /// What only a live or replayed `message.complete` carries: a billing link and the host's
    /// warning. Kept across a continuous reattach; cleared by the next turn or lost frames.
    private(set) var notice: HermesTurnOutcome?
    /// The failed turn's prompt as the host received it (`inflight.user`).
    private var failedPrompt: String?
    /// The host's row for the failed turn's prompt.
    private var failedPromptRowID: Int?
    /// A failed prompt's row the host refused to cut (4018): Retry hides for it.
    private var uncuttableRowID: Int?

    /// The plan while its turn runs with a step still open.
    var pinnedPlan: HermesPlan? {
        guard isTurnRunning, let plan = planState.plan, planTurn?.turn == turn, !plan.isFinished else { return nil }
        return plan
    }

    /// The plan in the transcript: once it is finished or its turn ended. Nil while pinned,
    /// cleared, or when its turn is older than the newest and its prompt's row is unknown.
    var settledPlan: SettledPlan? {
        guard pinnedPlan == nil, let plan = planState.plan, let planTurn else { return nil }
        let isInNewestTurn = planTurn.turn == turn
        guard isInNewestTurn || planTurn.rowID != nil else { return nil }
        return SettledPlan(plan: plan, rowID: planTurn.rowID, isInNewestTurn: isInNewestTurn)
    }

    /// Retry's resend and cut, when the host says retrying can help, it kept the prompt, and
    /// its row is known and cuttable.
    var retryTarget: RetryTarget? {
        guard failure?.offersRetry == true, let text = failedPrompt, let rowID = failedPromptRowID,
              rowID != uncuttableRowID else { return nil }
        return RetryTarget(rowID: rowID, text: text)
    }

    /// A turn started: the last turn's outcome goes.
    func turnDidStart() {
        turn += 1
        isTurnRunning = true
        failure = nil; notice = nil
        failedPrompt = nil; failedPromptRowID = nil
    }

    /// The running turn ended, however it ended: an open plan settles into it.
    func turnDidEnd() {
        isTurnRunning = false
    }

    /// `todo.updated`, or a snapshot's `todo_state`. A revision places the plan in the newest
    /// turn unless it is there already.
    func receivePlan(_ json: BotJSON) {
        var next = planState
        guard next.apply(json) else { return }
        planState = next
        if next.plan == nil {
            planTurn = nil
        } else if planTurn?.turn != turn {
            planTurn = PlanTurn(turn: turn)
        }
    }

    /// The running turn's `message.complete`: its failure, its notice, and the row the host
    /// saved its prompt as (`persisted_turn.user_row_id`).
    func turnDidComplete(_ payload: BotJSON) {
        let promptRowID = payload["persisted_turn"]["user_row_id"].integer
        if let promptRowID, planTurn?.turn == turn { planTurn?.rowID = promptRowID }
        let next = payload["status"].text == "error" ? HermesTurnOutcome(inflight: payload) : nil
        if next != failure { failure = next }
        failedPrompt = nil
        failedPromptRowID = next == nil ? nil : promptRowID
        notice = HermesTurnOutcome(complete: payload)
    }

    /// A `session.resume` snapshot: the retained failure and its raw prompt from `inflight`, and
    /// the plan from `todo_state`. `promptRowID` is the failed prompt's saved row when the
    /// chat's history holds it; `sameTurn` keeps the row already known for a failure the chat
    /// saw live, when no other turn can have run since.
    func readSnapshot(_ snapshot: BotJSON, promptRowID: Int?, sameTurn: Bool) {
        let inflight = snapshot["inflight"]
        let next = HermesTurnOutcome(inflight: inflight)
        if next != failure { failure = next }
        failedPrompt = next == nil ? nil : inflight["user"].text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        failedPromptRowID = next == nil ? nil : promptRowID ?? (sameTurn ? failedPromptRowID : nil)
        receivePlan(snapshot["todo_state"])
    }

    /// A new runtime counts its plan's revisions from the start again: the old plan goes.
    func dropPlan() {
        planState = HermesPlanState()
        planTurn = nil
    }

    /// Lost frames could hide a newer turn, so the live-only notice goes.
    func dropNotice() {
        if notice != nil { notice = nil }
    }

    /// The host refused to cut the failed prompt's row (4018): the same cut fails on every tap.
    func refuseRetry(at rowID: Int) {
        uncuttableRowID = rowID
    }
}
