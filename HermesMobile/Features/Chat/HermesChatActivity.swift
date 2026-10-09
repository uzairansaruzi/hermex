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

/// A Hermes chat's plan, how its last turn ended (#1139), and its delegated workers (#1140).
/// `HermesChatTurnCoordinator` owns it and only forwards its frames and snapshots here;
/// `ChatView` draws the plan pinned above the composer while its turn runs (`pinnedPlan`),
/// then at the top of that turn (`settledPlan`), the outcome row under the failed or warned
/// turn, and the workers button while `delegatedWork` counts any. Never cached.
@MainActor @Observable final class HermesChatActivity {
    /// A plan out of the strip, at the top of its turn: after that turn's prompt.
    struct SettledPlan: Equatable {
        let plan: HermesPlan
        /// The host's row for the turn's prompt, once `message.complete` or the history named it.
        let rowID: Int?
        /// The plan's turn is the newest and the chat showed its prompt, so that prompt is the
        /// transcript's last. Never for a turn another client started, which shows none.
        let followsLastPrompt: Bool

        /// The row the plan follows in `rows`: its turn's saved prompt, or, while that turn is the
        /// newest and the chat showed its prompt, the last prompt shown, unless that one is saved
        /// as another row: the saved prompt is gone, as after a cut. Nil hides the plan rather
        /// than draw it under another turn's prompt.
        func afterRenderID(in rows: [TranscriptMessage]) -> String? {
            if let rowID, let row = rows.last(where: { $0.message.rowID == rowID }) { return row.renderID }
            guard followsLastPrompt, let prompt = rows.last(where: { $0.message.role == "user" && !$0.message.isSteerMessage }),
                  rowID == nil || prompt.message.rowID == nil else { return nil }
            return prompt.renderID
        }
    }

    /// What Retry resends, the host's raw `inflight.user`, cut before the failed prompt's row.
    struct RetryTarget: Equatable {
        let rowID: Int
        let text: String
        /// The failed turn is the newest the chat saw and showed the prompt of itself, so an
        /// unsaved last prompt is that turn's. Never for a turn another client started.
        let showsPrompt: Bool
    }

    /// The turn a plan was revised in, counted by `turnDidStart`, and its prompt's row.
    private struct PlanTurn: Equatable {
        let turn: Int
        var rowID: Int?
        /// The chat showed the turn's prompt itself.
        let showsPrompt: Bool
    }

    /// The session's live workers, listed over the chat's own socket.
    let delegatedWork: HermesDelegatedWork

    init(wire: any BotTransport) {
        delegatedWork = HermesDelegatedWork(wire: wire)
    }

    private var planState = HermesPlanState()
    /// Nil for a plan no turn the chat saw is known to have revised, such as one a snapshot
    /// restored: the host keeps one plan across turns. It is held for revision order only.
    private var planTurn: PlanTurn?
    /// A new runtime dropped the plan, so the next snapshot's plan can't be placed in a turn.
    private var planRuntimeIsNew = false
    private var turn = 0
    private var isTurnRunning = false
    /// The chat showed the newest turn's prompt itself (`turnDidStart`).
    private var turnShowsPrompt = false
    /// The row the host saved the newest turn's prompt as, from its `message.complete`.
    private var turnPromptRowID: Int?

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
    /// The failed turn's `inflight.started_at`, which ties its prompt's row to it.
    private var failedTurnStartedAt: Double?
    /// A failed prompt's row the host refused to cut (4018): Retry hides for it.
    private var uncuttableRowID: Int?

    /// The plan while its turn runs with a step still open.
    var pinnedPlan: HermesPlan? {
        guard isTurnRunning, let plan = planState.plan, planTurn?.turn == turn, !plan.isFinished else { return nil }
        return plan
    }

    /// The plan in the transcript: once it is finished or its turn ended. Nil while pinned,
    /// cleared, when no turn is known to own it, or when its prompt's row is unknown and the
    /// last prompt shown may be another turn's.
    var settledPlan: SettledPlan? {
        guard pinnedPlan == nil, let plan = planState.plan, let planTurn else { return nil }
        let followsLastPrompt = planTurn.turn == turn && planTurn.showsPrompt
        guard followsLastPrompt || planTurn.rowID != nil else { return nil }
        return SettledPlan(plan: plan, rowID: planTurn.rowID, followsLastPrompt: followsLastPrompt)
    }

    /// Retry's resend and cut, when the host says retrying can help, it kept the prompt, and
    /// its row is known and cuttable. The failure read can name a later turn than the newest
    /// the chat saw, whose receipt then names another row.
    var retryTarget: RetryTarget? {
        guard failure?.offersRetry == true, let text = failedPrompt, let rowID = failedPromptRowID,
              rowID != uncuttableRowID else { return nil }
        return RetryTarget(rowID: rowID, text: text, showsPrompt: turnShowsPrompt && (turnPromptRowID ?? rowID) == rowID)
    }

    /// A turn started: the last turn's outcome goes. `showsPrompt` when the chat shows the
    /// turn's prompt itself, as for its own send or a prompt it queued; not for a turn another
    /// client started.
    func turnDidStart(showsPrompt: Bool) {
        turn += 1
        isTurnRunning = true
        turnShowsPrompt = showsPrompt
        turnPromptRowID = nil
        failure = nil; notice = nil
        failedPrompt = nil; failedPromptRowID = nil; failedTurnStartedAt = nil
    }

    /// The running turn ended, however it ended: an open plan settles into it.
    func turnDidEnd() {
        isTurnRunning = false
    }

    /// The running turn's `todo.updated`: the plan at that revision is this turn's, including
    /// one a snapshot already restored.
    func receivePlan(_ json: BotJSON) {
        guard applyRevision(json) || json["revision"].integer.map({ max(0, $0) }) == planState.revision else { return }
        placePlan(inTurn: true)
    }

    /// True when `json` changed the plan held.
    private func applyRevision(_ json: BotJSON) -> Bool {
        var next = planState
        guard next.apply(json) else { return false }
        planState = next
        return true
    }

    /// Places the plan held in the newest turn, whose prompt the host saved as `promptRowID`
    /// when known, or, when `inTurn` is false, in no known turn.
    private func placePlan(inTurn: Bool, promptRowID: Int? = nil) {
        if planState.plan == nil || !inTurn {
            if planTurn != nil { planTurn = nil }
        } else if planTurn?.turn != turn {
            planTurn = PlanTurn(turn: turn, rowID: promptRowID, showsPrompt: turnShowsPrompt)
        } else if let promptRowID, planTurn?.rowID != promptRowID {
            planTurn?.rowID = promptRowID
        }
    }

    /// The running turn's `message.complete`: its failure, its notice, and the row the host
    /// saved its prompt as (`persisted_turn.user_row_id`), where its plan settles. Retry's row
    /// waits for the snapshot that names the failed turn (`readSnapshot`).
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

    /// A `session.resume` snapshot: the retained failure and its raw prompt from `inflight`, and
    /// the plan from `todo_state`. `promptRowID` is the saved row of the prompt dated from the
    /// failed turn's `inflight.started_at`; without one, a row already known stays only for that
    /// same turn. `followsTurn` says the snapshot's plan is the newest turn's, the one the chat
    /// followed before it: still running, or ended with no turn since, its prompt saved as
    /// `followedPromptRowID`. So a plan revised since is that turn's, and a plan it already
    /// owned settles at that row; no other restored plan has a turn.
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

    /// `/undo` removed the newest exchange: a plan that turn revised goes with it.
    func newestTurnWasUndone() {
        if planTurn?.turn == turn { planTurn = nil }
    }

    /// A new runtime counts its plan's revisions from the start again: the old plan goes.
    func dropPlan() {
        planState = HermesPlanState()
        planTurn = nil
        planRuntimeIsNew = true
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
