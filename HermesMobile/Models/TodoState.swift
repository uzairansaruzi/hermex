import Foundation

/// One row of the agent's plan.
///
/// Mirrors `api/todo_state.py`'s per-item shape (`{id, content, status}`).
/// Every field is optional because upstream normalizes the list loosely — it
/// only guarantees `todos` is an array, never the shape of its elements.
struct TodoItem: Decodable, Equatable, Identifiable, Sendable {
    /// Upstream's own status vocabulary. `TODO_STATUS_RENDERING` in
    /// `static/ui.js` freezes exactly these four keys and falls back to
    /// `pending` for anything unrecognized; we mirror that fallback so a
    /// future server-side status can never render as a blank row.
    enum Status: String, Decodable, Equatable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled

        init(rawValueOrPending raw: String?) {
            self = Status(rawValue: raw ?? "") ?? .pending
        }

        /// Completed and cancelled both read as "no longer open" — upstream
        /// strikes through and dims both identically.
        var isResolved: Bool { self == .completed || self == .cancelled }
    }

    let rawID: String?
    let content: String
    let status: Status

    /// Stable identity for SwiftUI. Upstream ids are strings or ints depending
    /// on the agent, and can be absent entirely; falling back to the content
    /// keeps rows from being recycled onto each other mid-animation.
    var id: String { rawID ?? content }

    init(rawID: String?, content: String, status: Status) {
        self.rawID = rawID
        self.content = content
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case text
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawID = container.decodeLossyStringIfPresent(forKey: .id)
        // Upstream's `todoContent()` reads `content` then falls back to `text`.
        content = container.decodeLossyStringIfPresent(forKey: .content)
            ?? container.decodeLossyStringIfPresent(forKey: .text)
            ?? ""
        status = Status(rawValueOrPending: container.decodeLossyStringIfPresent(forKey: .status))
    }
}

/// A full snapshot of the agent's plan for a session.
///
/// **This is state, not history.** Upstream emits the entire list on every
/// `todo` tool call and its frontend comments are explicit that the snapshot is
/// "the single source of truth — never merge, always replace". A turn that
/// completes five steps sends five snapshots; rendering each one as its own
/// transcript card would stack five stale copies of the same plan. So this is
/// held as one piece of session state and rendered once.
///
/// An empty `todos` array is a *valid* snapshot meaning "the plan was cleared",
/// not "no data" — upstream calls out a past bug where guarding on non-empty
/// made the panel disagree with the agent. `nil` means no snapshot at all.
struct TodoState: Decodable, Equatable, Sendable {
    let todos: [TodoItem]
    let summary: TodoSummary
    let version: Int?
    /// Recency marker used to reconcile a live snapshot against a cold-loaded
    /// one. Present on both paths; see `supersedes(_:)`.
    let ts: Double?
    /// Only set on live SSE payloads, so events that arrive after the user has
    /// navigated away can be dropped instead of polluting another session.
    let sessionID: String?

    init(
        todos: [TodoItem],
        summary: TodoSummary? = nil,
        version: Int? = nil,
        ts: Double? = nil,
        sessionID: String? = nil
    ) {
        self.todos = todos
        self.summary = summary ?? TodoSummary(counting: todos)
        self.version = version
        self.ts = ts
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
        case todos
        case summary
        case version
        case ts
        case sessionId
        case snakeCasedSessionID = "session_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        todos = Self.decodeTodosTolerantly(from: container)
        // The server's summary is authoritative when present, but it is
        // normalized to `{}` on any malformed input, so recount as a fallback
        // rather than rendering "0 of 0" over a populated list.
        let decodedSummary = (try? container.decodeIfPresent(TodoSummary.self, forKey: .summary)) ?? nil
        summary = decodedSummary?.isEmpty == false ? decodedSummary! : TodoSummary(counting: todos)
        version = container.decodeLossyIntIfPresent(forKey: .version)
        ts = container.decodeLossyDoubleIfPresent(forKey: .ts)
        sessionID = container.decodeLossyStringIfPresent(forKey: .sessionId)
            ?? container.decodeLossyStringIfPresent(forKey: .snakeCasedSessionID)
    }

    /// Whether this snapshot should replace `other`.
    ///
    /// Upstream hit a real bug here: a todo message can lose its timestamp
    /// during context compaction, so the cold-load snapshot arrives with no
    /// `ts`. Comparing a missing timestamp as zero let a *stale* in-flight
    /// snapshot win and repaint an old plan. Treating a missing timestamp on
    /// either side as "cannot order these, take the newer arrival" keeps the
    /// most recently received snapshot authoritative, which matches the
    /// always-replace contract.
    func supersedes(_ other: TodoState?) -> Bool {
        guard let other else { return true }
        guard let mine = ts, let theirs = other.ts else { return true }
        return mine >= theirs
    }

    /// Decodes `todos` element by element, skipping malformed entries.
    ///
    /// An all-or-nothing `[TodoItem]` decode is dangerous here: upstream
    /// normalizes only that `todos` is a list and makes no guarantee about
    /// element shape, so one bad entry would throw, collapse the array to
    /// empty — and an empty array is a *valid* "plan cleared" snapshot, so it
    /// would supersede and hide a real plan rather than being ignored.
    private static func decodeTodosTolerantly(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [TodoItem] {
        if let direct = try? container.decodeIfPresent([TodoItem].self, forKey: .todos) {
            return direct
        }
        guard let values = try? container.decodeIfPresent([JSONValue].self, forKey: .todos) else {
            return []
        }
        let decoder = JSONDecoder()
        return values.compactMap { value in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? decoder.decode(TodoItem.self, from: data)
        }
    }

    /// 1-based position of the step being worked on, for the "3 of 5" pill.
    /// Falls back to the count of resolved rows so a plan whose in-progress
    /// step hasn't been marked yet still reads as forward progress.
    var currentStep: Int {
        if let index = todos.firstIndex(where: { $0.status == .inProgress }) {
            return index + 1
        }
        let resolved = todos.filter { $0.status.isResolved }.count
        return min(resolved + (resolved == todos.count ? 0 : 1), todos.count)
    }

    var isEmpty: Bool { todos.isEmpty }

    /// True once every row is completed or cancelled.
    var isFinished: Bool { !todos.isEmpty && todos.allSatisfy { $0.status.isResolved } }

    /// Any step was cancelled. A finished-but-cancelled plan must not render as
    /// a success.
    var hasCancelledWork: Bool { todos.contains { $0.status == .cancelled } }
}

struct TodoSummary: Decodable, Equatable, Sendable {
    let total: Int
    let pending: Int
    let inProgress: Int
    let completed: Int
    let cancelled: Int

    init(total: Int, pending: Int, inProgress: Int, completed: Int, cancelled: Int) {
        self.total = total
        self.pending = pending
        self.inProgress = inProgress
        self.completed = completed
        self.cancelled = cancelled
    }

    init(counting todos: [TodoItem]) {
        total = todos.count
        pending = todos.filter { $0.status == .pending }.count
        inProgress = todos.filter { $0.status == .inProgress }.count
        completed = todos.filter { $0.status == .completed }.count
        cancelled = todos.filter { $0.status == .cancelled }.count
    }

    enum CodingKeys: String, CodingKey {
        case total
        case pending
        case inProgress
        case snakeCasedInProgress = "in_progress"
        case completed
        case cancelled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = container.decodeLossyIntIfPresent(forKey: .total) ?? 0
        pending = container.decodeLossyIntIfPresent(forKey: .pending) ?? 0
        inProgress = container.decodeLossyIntIfPresent(forKey: .inProgress)
            ?? container.decodeLossyIntIfPresent(forKey: .snakeCasedInProgress)
            ?? 0
        completed = container.decodeLossyIntIfPresent(forKey: .completed) ?? 0
        cancelled = container.decodeLossyIntIfPresent(forKey: .cancelled) ?? 0
    }

    /// An all-zero summary is what upstream's `{}` normalization produces.
    var isEmpty: Bool {
        total == 0 && pending == 0 && inProgress == 0 && completed == 0 && cancelled == 0
    }
}
