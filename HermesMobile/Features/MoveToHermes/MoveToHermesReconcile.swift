import Foundation

/// Move to Hermes's reconcile (#1214): fills the titles, pins and folders the import (#1213)
/// leaves out, and moves each chat's unsent draft from the webui to Hermes. It never writes over
/// a value Hermes holds, and never resends a change whose result is unknown.
///
/// The runner (#1216) drives it in three steps and journals between them:
/// 1. `plan` reads each chat's Hermes row once. That read is the snapshot, and every planned
///    `Operation` records its field's value there as `from`. The runner saves the plan before
///    anything is sent.
/// 2. `apply` reads the row again before sending. A field still at `from` is written, after
///    `willDispatch` records it; one already at `to` counts as applied; anything else changed in
///    Hermes meanwhile and is left alone. A pin, unpinned and pinned again in between, reads as
///    unchanged: the host keeps no per-field version, and an edit between this read and the
///    write still loses to the write.
/// 3. `settle` checks a write whose result never arrived, including one the journal still shows
///    in flight after a quit: applied when Hermes holds `to`, otherwise uncertain and reported,
///    never sent again, even when the field is back at `from`.
///
/// Titles and folders fill only a field Hermes has empty. A pin is filled only on a chat this
/// Move copied, whose unpinned state is the import's own default; a chat Hermes already had keeps
/// its pin and archive state, since its `false` may be the user's choice. Archive state needs no
/// step: the import carries it. Unread state is the host's own and is never moved.
enum MoveToHermesReconcile {
    /// One webui chat in Hermes that reconcile fills: where it is, and whether this Move copied it.
    struct Target: Codable, Equatable, Sendable {
        let chat: MoveToHermesSourceChat
        /// The Hermes Profile holding it.
        let profile: String
        /// True for a chat this Move imported; false for one Hermes already had.
        let copied: Bool
    }

    /// One field change, with its value in the snapshot (`from`) and the value it writes (`to`).
    enum Change: Codable, Hashable, Sendable {
        case title(from: String?, to: String)
        case pinned(from: Bool, to: Bool)
        case folder(from: String?, to: String)
    }

    /// One change to one Hermes session, as the journal records it before dispatch.
    struct Operation: Codable, Hashable, Sendable {
        let id: String
        let profile: String
        let change: Change
    }

    /// One chat's planned changes, and the session id its Hermes draft is keyed by.
    struct Plan: Codable, Equatable, Sendable {
        let target: Target
        /// The chat's id when the snapshot shows the Hermes Sessions list keys its draft by it: a
        /// visible row with no parent. A row with a parent may continue a compression chain whose
        /// root keys the draft, or be a branch keyed by its own id; the client can't tell which,
        /// so nil leaves the draft on the webui and reports it.
        let draftSession: String?
        let operations: [Operation]
    }

    /// What reading one chat's snapshot gave.
    enum Planned: Codable, Equatable, Sendable {
        case plan(Plan)
        /// Hermes no longer has the session.
        case missing
        /// Its row couldn't be read. Nothing was planned or sent, so it can be planned again.
        case unread
    }

    /// What became of one operation.
    enum Outcome: Codable, Equatable, Sendable {
        /// Hermes holds the value: written now, already there, or found by `settle`.
        case applied
        /// Hermes's value changed after the snapshot, so it was left alone.
        case changed
        /// The Hermes host has no such folder (4017).
        case folderMissing
        /// Hermes no longer has the session.
        case missing
        /// The host refused it and wrote nothing, such as a title still in use after its one
        /// suffixed retry.
        case rejected(reason: String)
        /// Nothing was written: its row couldn't be read, the run was cancelled, `willDispatch`
        /// threw first, or the host's write fence found the session moved on (#1300). Safe to
        /// apply again.
        case notSent
        /// Sent, but the result never arrived and Hermes doesn't hold the value. Reported, never
        /// sent again.
        case uncertain
    }

    /// What became of one chat's draft.
    enum DraftOutcome: Equatable, Sendable {
        case moved(ChatDraftTransfer)
        /// Its Hermes draft key couldn't be verified (`Plan.draftSession`), or the row now has a
        /// parent or is hidden, so it stays on the webui.
        case unverified
        /// Hermes no longer has the session, so the draft stays on the webui.
        case missing
        /// Not moved this time: the row couldn't be read or saving failed. Both drafts are kept,
        /// and moving it again is safe.
        case failed
    }

    /// The chats reconcile fills. The first move takes the chats this run imported (`copied`)
    /// and every chat Hermes already had; Copy Missing Chats Again takes only the ones it
    /// imported, so a later run never re-applies the webui's values over changes made in Hermes.
    /// A runner replaying its own uncertain import builds that chat's `Target` itself.
    static func targets(_ entries: [MoveToHermesScan.Entry], outcomes: [String: WebuiSessionTransfer.Outcome],
                        firstMove: Bool) -> [Target] {
        entries.compactMap { entry in
            switch outcomes[entry.chat.id] {
            case .imported(let profile)?:
                return Target(chat: entry.chat, profile: profile, copied: true)
            case .alreadyPresent(let profile)? where firstMove:
                return Target(chat: entry.chat, profile: profile, copied: false)
            case nil:
                guard firstMove, case .present(let profile) = entry.location else { return nil }
                return Target(chat: entry.chat, profile: profile, copied: false)
            default:
                return nil
            }
        }
    }

    /// Reads each target's Hermes row and plans its changes from that snapshot, keyed by chat id.
    @MainActor
    static func plan(_ targets: [Target], on hermes: any BotTransport) async -> [String: Planned] {
        let planned = await MoveToHermesRequests.map(targets) { target -> Planned in
            switch await snapshot(target.chat.id, in: target.profile, on: hermes) {
            case .row(let row):
                let drafts = !row.hidden && row.parent == nil
                return .plan(Plan(target: target, draftSession: drafts ? target.chat.id : nil,
                                  operations: operations(for: target, snapshot: row)))
            case .missing: return .missing
            case .unread: return .unread
            }
        }
        return Dictionary(zip(targets.map(\.chat.id), planned), uniquingKeysWith: { first, _ in first })
    }

    /// The changes `target` needs given its Hermes row. A hidden row gets none: `pinned: true`
    /// would unhide it, and nothing lists it.
    static func operations(for target: Target, snapshot row: Snapshot) -> [Operation] {
        guard !row.hidden else { return [] }
        var changes: [Change] = []
        if row.title == nil, let title = fillTitle(target.chat.title) { changes.append(.title(from: nil, to: title)) }
        if target.copied, target.chat.pinned, !row.pinned { changes.append(.pinned(from: false, to: true)) }
        if row.folder == nil, let folder = nonEmpty(target.chat.workspace) { changes.append(.folder(from: nil, to: folder)) }
        return changes.map { Operation(id: target.chat.id, profile: target.profile, change: $0) }
    }

    /// Sends each of `operations` whose field still holds its `from`, after `willDispatch`
    /// records it. Each reads its session's row just before; a session's operations run in order,
    /// and at most `MoveToHermesRequests.perServer` sessions at once. When `willDispatch` throws,
    /// nothing more is sent. A title the host says is in use is tried once more with a short id
    /// suffix (`suffixed`), recorded through `willDispatch` like any other write.
    @MainActor
    static func apply(_ operations: [Operation], on hermes: any BotTransport,
                      willDispatch: @escaping @MainActor (Operation) async throws -> Void) async -> [Operation: Outcome] {
        var stopped = false
        func send(_ operation: Operation, retried: Bool = false) async -> Outcome {
            guard !stopped, !Task.isCancelled else { return .notSent }
            let row: Snapshot
            switch await snapshot(operation.id, in: operation.profile, on: hermes) {
            case .row(let read): row = read
            case .missing: return .missing
            case .unread: return .notSent
            }
            // Hidden since planning: `pinned: true` would unhide it, so it is left as Hermes has it.
            guard !row.hidden else { return .changed }
            switch state(of: operation.change, in: row) {
            case .to: return .applied
            case .other: return .changed
            case .from: break
            }
            guard !stopped, !Task.isCancelled else { return .notSent }
            do {
                try await willDispatch(operation)
            } catch {
                stopped = true
                return .notSent
            }
            do {
                try await write(operation.change, id: operation.id, profile: operation.profile, on: hermes)
                return .applied
            } catch let refusal as HermesSessionRefusal {
                if !retried, case .title(let from, let title) = operation.change, refusal.message.contains("already in use") {
                    let retry = Operation(id: operation.id, profile: operation.profile,
                                          change: .title(from: from, to: suffixed(title, id: operation.id)))
                    return await send(retry, retried: true)
                }
                return .rejected(reason: refusal.message)
            } catch HermesSessionFenceRefusal.changed {
                return .notSent
            } catch let refusal as HermesSessionFenceRefusal {
                return .rejected(reason: refusal.localizedDescription)
            } catch BotFailure.rejected(404) {
                return .missing
            } catch BotFailure.rejected(let status) where (400..<500).contains(status) && ![408, 429].contains(status) {
                return .rejected(reason: BotFailure.rejected(status).localizedDescription)
            } catch BotSettingFailure.rejected(4017, _) {
                return .folderMissing
            } catch BotSettingFailure.rejected(4007, _) {
                return .missing
            } catch BotSettingFailure.rejected(_, let message) {
                return .rejected(reason: message)
            } catch {
                // A timeout, a rate limit or a lost reply: read once to see whether it landed.
                return await settle([operation], on: hermes)[operation] ?? .uncertain
            }
        }
        let groups = sessions(of: operations)
        let results = await MoveToHermesRequests.map(groups) { group -> [Outcome] in
            var outcomes: [Outcome] = []
            for operation in group { outcomes.append(await send(operation)) }
            return outcomes
        }
        return Dictionary(zip(groups.joined(), results.joined()), uniquingKeysWith: { first, _ in first })
    }

    /// Settles `operations` whose writes went out without a known result: `.applied` when Hermes
    /// holds `to`, otherwise `.uncertain`, never sent again. An operation whose row can't be read
    /// is left out, to settle later.
    @MainActor
    static func settle(_ operations: [Operation], on hermes: any BotTransport) async -> [Operation: Outcome] {
        let groups = sessions(of: operations)
        let results = await MoveToHermesRequests.map(groups) { group -> [Outcome?] in
            guard let first = group.first else { return [] }
            switch await snapshot(first.id, in: first.profile, on: hermes) {
            case .row(let row): return group.map { state(of: $0.change, in: row) == .to ? .applied : .uncertain }
            case .missing: return group.map { _ in .missing }
            case .unread: return group.map { _ in nil }
            }
        }
        var settled: [Operation: Outcome] = [:]
        for (operation, outcome) in zip(groups.joined(), results.joined()) {
            if let outcome { settled[operation] = outcome }
        }
        return settled
    }

    /// Moves each planned chat's webui draft to its Hermes session draft (`ChatDraftStore.transferDraft`),
    /// keyed by chat id. `webui` and `hermes` are the server URLs the app keys those servers'
    /// drafts by; `connectionID` is the Hermes connection. Each chat with a draft has its row read
    /// again first, since a plan can be old: a deleted, hidden or parented row keeps its draft on
    /// the webui, as does a chat whose plan didn't verify its key. Chats left out keep theirs too.
    /// `canTransfer` is asked just before each transfer; false keeps the draft (`.failed`), as when
    /// the Hermes server is being removed while its row was read.
    @MainActor
    static func moveDrafts(_ plans: [Plan], webui: URL, hermes: URL, connectionID: UUID,
                           store: ChatDraftStore, on transport: any BotTransport,
                           canTransfer: @MainActor () -> Bool = { true }) async -> [String: DraftOutcome] {
        var outcomes: [String: DraftOutcome] = [:]
        for plan in plans {
            let id = plan.target.chat.id
            let source = ChatDraftKey.session(server: webui, sessionID: id)
            guard await store.draft(for: source)?.isEmpty == false else {
                outcomes[id] = .moved(.nothingToMove)
                continue
            }
            guard let session = plan.draftSession else {
                outcomes[id] = .unverified
                continue
            }
            switch await snapshot(session, in: plan.target.profile, on: transport) {
            case .row(let row) where row.hidden || row.parent != nil:
                outcomes[id] = .unverified
                continue
            case .row: break
            case .missing:
                outcomes[id] = .missing
                continue
            case .unread:
                outcomes[id] = .failed
                continue
            }
            let destination = ChatDraftKey.hermesSession(server: hermes, connectionID: connectionID,
                                                         profile: plan.target.profile, key: session)
            guard canTransfer() else {
                outcomes[id] = .failed
                continue
            }
            do {
                outcomes[id] = .moved(try await store.transferDraft(from: source, to: destination))
            } catch {
                outcomes[id] = .failed
            }
        }
        return outcomes
    }

    // MARK: Snapshot

    /// The fields reconcile reads from a Hermes session row (`GET /api/sessions/{id}`). SQLite
    /// flags may come as `0`/`1`; blank text reads as none.
    struct Snapshot: Equatable, Sendable {
        var title: String?
        var pinned = false
        var hidden = false
        var folder: String?
        var parent: String?

        init(title: String? = nil, pinned: Bool = false, hidden: Bool = false, folder: String? = nil, parent: String? = nil) {
            self.title = title
            self.pinned = pinned
            self.hidden = hidden
            self.folder = folder
            self.parent = parent
        }

        init(_ row: BotJSON) {
            func flag(_ value: BotJSON) -> Bool { value.flag ?? value.integer.map { $0 != 0 } ?? false }
            self.init(title: nonEmpty(row["title"].text), pinned: flag(row["pinned"]), hidden: flag(row["hidden"]),
                      folder: nonEmpty(row["cwd"].text), parent: nonEmpty(row["parent_session_id"].text))
        }
    }

    private enum Read {
        case row(Snapshot)
        case missing
        case unread
    }

    /// The exact row `id` in `profile`. The host falls back to a unique prefix, so a row under
    /// another id is missing, as in the scan.
    @MainActor
    private static func snapshot(_ id: String, in profile: String, on hermes: any BotTransport) async -> Read {
        guard !Task.isCancelled else { return .unread }
        do {
            guard let row = try await hermes.sessionRow(key: id, profile: profile), row["id"].text == id else { return .missing }
            return .row(Snapshot(row))
        } catch {
            return .unread
        }
    }

    private enum FieldState { case from, to, other }

    private static func state(of change: Change, in row: Snapshot) -> FieldState {
        func compare<Value: Equatable>(_ current: Value, _ from: Value, _ to: Value) -> FieldState {
            current == to ? .to : current == from ? .from : .other
        }
        switch change {
        case .title(let from, let to): return compare(row.title, from, to)
        case .pinned(let from, let to): return compare(row.pinned, from, to)
        case .folder(let from, let to): return compare(row.folder.map(trimmingSlash), from.map(trimmingSlash), trimmingSlash(to))
        }
    }

    @MainActor
    private static func write(_ change: Change, id: String, profile: String, on hermes: any BotTransport) async throws {
        switch change {
        case .title(_, let title): try await hermes.updateSession(.title(title), key: id, profile: profile)
        case .pinned(_, let pinned): try await hermes.updateSession(.pinned(pinned), key: id, profile: profile)
        case .folder(_, let folder): _ = try await hermes.call(.sessionWorkspaceMove(profile: profile, storedKey: id, cwd: folder))
        }
    }

    /// `operations` grouped by session, in first-seen order, each group in its given order.
    private static func sessions(of operations: [Operation]) -> [[Operation]] {
        var order: [String] = []
        var groups: [String: [Operation]] = [:]
        for operation in operations {
            let key = operation.profile + "\u{0}" + operation.id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(operation)
        }
        return order.compactMap { groups[$0] }
    }

    // MARK: Titles

    /// The host's title cap, counted in Unicode scalars as its Python `len` counts.
    static let titleLimit = 100

    /// The title the webui chat gives Hermes, cleaned the way the host cleans titles
    /// (`hermes_state_titles.sanitize_title`) and cut to its cap; nil for none or the webui's
    /// `Untitled` placeholder.
    static func fillTitle(_ title: String?) -> String? {
        guard let cleaned = sanitized(title), cleaned != "Untitled" else { return nil }
        return capped(cleaned, to: titleLimit)
    }

    /// `title` with a short suffix from the session id, `Title (a1b2c3)`, cut so the whole stays
    /// under the host's cap. Tried once after the host says a title is in use; a second
    /// collision is reported, not retried.
    static func suffixed(_ title: String, id: String) -> String {
        let suffix = " (\(id.suffix(6)))"
        let base = capped(title, to: titleLimit - suffix.unicodeScalars.count)
        return base.trimmingCharacters(in: .whitespaces) + suffix
    }

    /// The host's cleaning: control and invisible characters dropped, whitespace runs collapsed
    /// to one space, ends trimmed; nil when nothing is left.
    static func sanitized(_ title: String?) -> String? {
        guard let title else { return nil }
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in title.unicodeScalars where !isDropped(scalar) {
            if scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace { scalars.append(" ") }
            pendingSpace = false
            scalars.append(scalar)
        }
        return scalars.isEmpty ? nil : String(scalars)
    }

    /// Control and invisible characters the host strips (`_TITLE_CONTROL_RE`, `_TITLE_INVISIBLE_RE`).
    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F,
             0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2069, 0xFEFF, 0xFFF9...0xFFFC:
            return true
        default:
            return false
        }
    }

    private static func capped(_ text: String, to limit: Int) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > limit else { return text }
        return String(String.UnicodeScalarView(scalars.prefix(limit)))
    }

    private static func trimmingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
