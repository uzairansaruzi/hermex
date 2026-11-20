import Foundation

enum MoveToHermesReconcile {
    struct Target: Codable, Equatable, Sendable {
        let chat: MoveToHermesSourceChat
        let profile: String
        let copied: Bool
    }

    enum Change: Codable, Hashable, Sendable {
        case title(from: String?, to: String)
        case pinned(from: Bool, to: Bool)
        case folder(from: String?, to: String)
    }

    struct Operation: Codable, Hashable, Sendable {
        let id: String
        let profile: String
        let change: Change
    }

    struct Plan: Codable, Equatable, Sendable {
        let target: Target
        let draftSession: String?
        let operations: [Operation]
    }

    enum Planned: Codable, Equatable, Sendable {
        case plan(Plan)
        case missing
        case unread
    }

    enum Outcome: Codable, Equatable, Sendable {
        case applied
        case changed
        case folderMissing
        case missing
        case rejected(reason: String)
        case notSent
        case uncertain
    }

    enum DraftOutcome: Equatable, Sendable {
        case moved(ChatDraftTransfer)
        case unverified
        case missing
        case failed
    }

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

    static func operations(for target: Target, snapshot row: Snapshot) -> [Operation] {
        guard !row.hidden else { return [] }
        var changes: [Change] = []
        if row.title == nil, let title = fillTitle(target.chat.title) { changes.append(.title(from: nil, to: title)) }
        if target.copied, target.chat.pinned, !row.pinned { changes.append(.pinned(from: false, to: true)) }
        if row.folder == nil, let folder = nonEmpty(target.chat.workspace) { changes.append(.folder(from: nil, to: folder)) }
        return changes.map { Operation(id: target.chat.id, profile: target.profile, change: $0) }
    }

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

    static let titleLimit = 100

    static func fillTitle(_ title: String?) -> String? {
        guard let cleaned = sanitized(title), cleaned != "Untitled" else { return nil }
        return capped(cleaned, to: titleLimit)
    }

    static func suffixed(_ title: String, id: String) -> String {
        let suffix = " (\(id.suffix(6)))"
        let base = capped(title, to: titleLimit - suffix.unicodeScalars.count)
        return base.trimmingCharacters(in: .whitespaces) + suffix
    }

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
