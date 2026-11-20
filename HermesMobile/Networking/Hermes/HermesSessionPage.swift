import Foundation

struct HermesSessionPage: Decodable, Equatable {
    let rows: [HermesSessionRow]
    let count: Int
    let total: Int?

    init(rows: [HermesSessionRow], count: Int? = nil, total: Int? = nil) {
        self.rows = rows
        self.count = count ?? rows.count
        self.total = total
    }

    enum CodingKeys: String, CodingKey { case sessions, total }

    init(from decoder: Decoder) throws {
        let slots = try decoder.container(keyedBy: CodingKeys.self).decode([Slot].self, forKey: .sessions)
        rows = slots.compactMap(\.row)
        count = slots.count
        total = try decoder.container(keyedBy: CodingKeys.self).decodeLossyIntIfPresent(forKey: .total)
    }

    private struct Slot: Decodable {
        let row: HermesSessionRow?
        init(from decoder: Decoder) throws { row = try? HermesSessionRow(from: decoder) }
    }
}

struct HermesSessionRow: Decodable, Equatable {
    let id: String
    let source: String?
    let createdSource: String?
    var title: String?
    let preview: String?
    let lastActive: Double?
    let startedAt: Double?
    var pinned: Bool?
    var archived: Bool?
    let unread: Bool?
    let hidden: Bool?
    let model: String?
    let cwd: String?
    let messageCount: Int?
    let profile: String?
    let parentSessionID: String?
    let lineageRootID: String?

    var identity: String { lineageRootID ?? id }

    var isBotChat: Bool { hidden == true && title == HermesCall.botChatTitle }

    var botChatRoot: String? {
        guard hidden == true else { return nil }
        if title == HermesCall.botChatTitle { return identity }
        return title == HermesCall.botChatTitle + " (continued)" ? lineageRootID : nil
    }

    var isRoomSession: Bool { hidden != false && title?.hasPrefix("Group: ") == true }

    enum CodingKeys: String, CodingKey {
        case id, title, preview, pinned, archived, unread, hidden, model, cwd, profile, source
        case createdSource = "created_source"
        case lastActive = "last_active", startedAt = "started_at", messageCount = "message_count"
        case parentSessionID = "parent_session_id", lineageRootID = "_lineage_root_id"
    }

    init(id: String, title: String? = nil, preview: String? = nil, lastActive: Double? = nil, startedAt: Double? = nil,
         pinned: Bool? = nil, archived: Bool? = nil, unread: Bool? = nil, hidden: Bool? = nil, model: String? = nil,
         cwd: String? = nil, messageCount: Int? = nil, profile: String? = nil, parentSessionID: String? = nil,
         lineageRootID: String? = nil, source: String? = nil, createdSource: String? = nil) {
        self.id = id; self.title = title; self.preview = preview; self.lastActive = lastActive; self.startedAt = startedAt
        self.pinned = pinned; self.archived = archived; self.unread = unread; self.hidden = hidden; self.model = model
        self.cwd = cwd; self.messageCount = messageCount; self.profile = profile; self.parentSessionID = parentSessionID
        self.lineageRootID = lineageRootID
        self.source = source
        self.createdSource = createdSource
    }

    init(from decoder: Decoder) throws {
        let row = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = row.decodeLossyStringIfPresent(forKey: .id), !id.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A session row without an id"))
        }
        let time = { (key: CodingKeys) in row.decodeLossyDoubleIfPresent(forKey: key).flatMap { $0.isFinite ? $0 : nil } }
        let root = row.decodeLossyStringIfPresent(forKey: .lineageRootID)
        self.init(
            id: id, title: row.decodeLossyStringIfPresent(forKey: .title), preview: row.decodeLossyStringIfPresent(forKey: .preview),
            lastActive: time(.lastActive), startedAt: time(.startedAt), pinned: row.decodeLossyBoolIfPresent(forKey: .pinned),
            archived: row.decodeLossyBoolIfPresent(forKey: .archived), unread: row.decodeLossyBoolIfPresent(forKey: .unread),
            hidden: row.decodeLossyBoolIfPresent(forKey: .hidden),
            model: row.decodeLossyStringIfPresent(forKey: .model), cwd: row.decodeLossyStringIfPresent(forKey: .cwd),
            messageCount: row.decodeLossyIntIfPresent(forKey: .messageCount), profile: row.decodeLossyStringIfPresent(forKey: .profile),
            parentSessionID: row.decodeLossyStringIfPresent(forKey: .parentSessionID),
            lineageRootID: root?.isEmpty == false ? root : nil, source: row.decodeLossyStringIfPresent(forKey: .source),
            createdSource: row.decodeLossyStringIfPresent(forKey: .createdSource)
        )
    }

    func summary(in profile: String, project: String? = nil) -> SessionSummary {
        let profile = self.profile.flatMap { $0.isEmpty ? nil : $0 } ?? profile
        let origin = source == "local" ? createdSource.flatMap { $0.isEmpty ? nil : $0 } ?? source : source
        return SessionSummary(
            sessionId: id, title: isBotChat ? String(localized: "Bot Chat · \(profile)") : MessageAttachment.hermesTitle(title),
            workspace: cwd, model: model, messageCount: messageCount, createdAt: startedAt, lastMessageAt: lastActive,
            pinned: pinned, archived: archived, projectId: project, profile: profile, sessionSource: origin, parentSessionId: parentSessionID,
            hermes: SessionSummary.Hermes(lineageRoot: identity, unread: unread == true,
                                          preview: MessageAttachment.hermesTitle(preview), isBotChat: isBotChat,
                                          botChatRoot: botChatRoot)
        )
    }
}

struct HermesSessionSearch: Decodable, Equatable {
    let results: [HermesSessionSearchResult]

    init(results: [HermesSessionSearchResult]) {
        self.results = results
    }

    enum CodingKeys: String, CodingKey { case results }

    init(from decoder: Decoder) throws {
        results = try decoder.container(keyedBy: CodingKeys.self).decode([Slot].self, forKey: .results)
            .compactMap(\.result).filter { !$0.row.isRoomSession }
    }

    private struct Slot: Decodable {
        let result: HermesSessionSearchResult?
        init(from decoder: Decoder) throws { result = try? HermesSessionSearchResult(from: decoder) }
    }
}

struct HermesSessionSearchResult: Decodable, Equatable {
    let row: HermesSessionRow
    let snippet: String?
    let role: String?

    init(row: HermesSessionRow, snippet: String? = nil, role: String? = nil) {
        self.row = row
        self.snippet = snippet
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", id, title, preview, archived, model, profile, snippet, role, source
        case lineageRoot = "lineage_root", lastActive = "last_active", sessionStarted = "session_started"
        case startedAt = "started_at", messageCount = "message_count", parentSessionID = "parent_session_id"
    }

    init(from decoder: Decoder) throws {
        let result = try decoder.container(keyedBy: CodingKeys.self)
        let nonEmpty = { (key: CodingKeys) in result.decodeLossyStringIfPresent(forKey: key).flatMap { $0.isEmpty ? nil : $0 } }
        guard let id = nonEmpty(.sessionID) ?? nonEmpty(.id) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A search result without an id"))
        }
        let time = { (key: CodingKeys) in result.decodeLossyDoubleIfPresent(forKey: key).flatMap { $0.isFinite ? $0 : nil } }
        let title = result.decodeLossyStringIfPresent(forKey: .title)
        row = HermesSessionRow(
            id: id, title: title, preview: result.decodeLossyStringIfPresent(forKey: .preview),
            lastActive: time(.lastActive) ?? time(.sessionStarted), startedAt: time(.startedAt) ?? time(.sessionStarted),
            archived: result.decodeLossyBoolIfPresent(forKey: .archived),
            hidden: title == HermesCall.botChatTitle ? true : nil,
            model: result.decodeLossyStringIfPresent(forKey: .model), messageCount: result.decodeLossyIntIfPresent(forKey: .messageCount),
            profile: nonEmpty(.profile), parentSessionID: nonEmpty(.parentSessionID), lineageRootID: nonEmpty(.lineageRoot), source: nonEmpty(.source)
        )
        role = nonEmpty(.role)
        snippet = role == nil ? nil : nonEmpty(.snippet)
    }
}

struct HermesSessionPages: Equatable {
    let archived: Bool
    private(set) var rows: [HermesSessionRow] = []
    private(set) var nextOffset = 0
    private(set) var hasMore = true
    private var identities: Set<String> = []
    private(set) var total: Int?
    var totalCount: Int { total ?? rows.count }

    init(archived: Bool = false) {
        self.archived = archived
    }

    mutating func append(_ page: HermesSessionPage) {
        total = page.total
        var added = 0
        for row in page.rows where (row.archived == true) == archived && identities.insert(row.identity).inserted {
            added += 1
            if !row.isRoomSession { rows.append(row) }
        }
        nextOffset += HermesREST.sessionPageSize
        hasMore = page.count >= HermesREST.sessionPageSize && added > 0
    }

    func row(_ id: String) -> HermesSessionRow? { rows.first { $0.id == id } }

    mutating func apply(_ change: HermesSessionChange, to id: String) -> (row: HermesSessionRow, index: Int)? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let before = rows[index]
        switch change {
        case .pinned(let pinned): rows[index].pinned = pinned
        case .title(let title): rows[index].title = title
        case .archived(let archived) where archived != self.archived: remove(id)
        case .archived, .unread: break
        }
        return (before, index)
    }

    mutating func remove(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        identities.remove(rows.remove(at: index).identity)
        if let total { self.total = max(total - 1, 0) }
        nextOffset = max(nextOffset - 1, 0)
    }

    mutating func restore(_ row: HermesSessionRow, at index: Int) {
        if let current = rows.firstIndex(where: { $0.identity == row.identity }) { rows[current] = row; return }
        rows.insert(row, at: min(index, rows.count))
        identities.insert(row.identity)
        if let total { self.total = total + 1 }
        nextOffset += 1
    }
}

struct HermesProfilePages: Equatable {
    private var pages: [String: HermesSessionPages] = [:]

    subscript(profile: String) -> HermesSessionPages {
        get { pages[profile] ?? HermesSessionPages() }
        set { pages[profile] = newValue }
    }

    var hasMore: Bool { pages.values.contains(where: \.hasMore) }
    var totalCount: Int { pages.values.reduce(0) { $0 + $1.totalCount } }

    var rows: [(profile: String, row: HermesSessionRow)] {
        let frontier = pages.count > 1 ? self.frontier : nil
        return pages.keys.sorted().flatMap { profile in
            pages[profile]!.rows.compactMap { row in
                guard let frontier, row.pinned != true, Self.recency(row) < frontier else { return (profile, row) }
                return nil
            }
        }
    }

    func profile(holding id: String) -> String? {
        pages.first { $0.value.row(id) != nil }?.key
    }

    mutating func apply(_ change: HermesSessionChange, to id: String) -> (profile: String, row: HermesSessionRow, index: Int)? {
        guard let profile = profile(holding: id), let before = pages[profile]?.apply(change, to: id) else { return nil }
        return (profile, before.row, before.index)
    }

    mutating func remove(_ id: String) {
        guard let profile = profile(holding: id) else { return }
        pages[profile]?.remove(id)
    }

    private var frontier: Double? {
        pages.values.filter(\.hasMore).compactMap { $0.rows.filter { $0.pinned != true }.map(Self.recency).min() }.max()
    }

    private static func recency(_ row: HermesSessionRow) -> Double { row.lastActive ?? row.startedAt ?? 0 }
}

extension SessionRowAttentionState {
    static func hermesStates(_ items: [BotJSON]) -> [String: SessionRowAttentionState] {
        var states: [String: SessionRowAttentionState] = [:]
        for item in items {
            guard let key = item["session_key"].text, !key.isEmpty,
                  let status = BotLiveStatus(wire: item["status"].text) else { continue }
            if status == .waiting || states[key] == nil { states[key] = status == .waiting ? .input : .working }
        }
        return states
    }
}
