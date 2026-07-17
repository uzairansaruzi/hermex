import Foundation

struct KanbanCreateCardRequest: Equatable, Sendable {
    let board: String
    let title: String
    let body: String?
    let status: String
    let priority: Int?
    let assignee: String?
    let tenant: String?
    let workspaceKind: String
    let workspacePath: String?
    let skills: [String]?
    let maxRuntimeSeconds: Int?
    let prerequisiteID: String?
    let idempotencyKey: String

    var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "board", value: board)]
    }
}

struct KanbanEditCardRequest: Equatable, Sendable {
    let cardID: String
    let board: String
    let title: String
    let body: String
    let tenant: String?
    let priority: Int
    let assignee: String?
    let status: String?

    var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "board", value: board)]
    }
}

struct KanbanCardStatusRequest: Equatable, Sendable {
    let cardID: String
    let board: String
    let status: String

    var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "board", value: board)]
    }
}

struct KanbanCardActionRequest: Equatable, Sendable {
    let cardID: String
    let board: String
    let reason: String?

    var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "board", value: board)]
    }
}

struct KanbanDependencyMutationRequest: Equatable, Sendable {
    let board: String
    let prerequisiteID: String
    let dependentID: String

    var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "board", value: board)]
    }
}

struct KanbanCardDetailRequest: Equatable, Sendable {
    let cardID: String
    let board: String

    var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "board", value: board)]
    }
}

struct KanbanWorkerLogRequest: Equatable, Sendable {
    let cardID: String
    let board: String
    var tailBytes: Int = 65_536

    var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "board", value: board),
            URLQueryItem(name: "tail", value: String(min(max(1, tailBytes), 2_000_000)))
        ]
    }
}

struct KanbanAddCommentRequest: Equatable, Sendable {
    let cardID: String
    let board: String
    let body: String

    var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "board", value: board)]
    }
}

struct KanbanEventsRequest: Equatable, Sendable {
    let board: String
    let since: Int
    var limit: Int = 200

    var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "board", value: board),
            URLQueryItem(name: "since", value: String(max(0, since))),
            URLQueryItem(name: "limit", value: String(min(max(1, limit), 200)))
        ]
    }
}

struct KanbanEventsStreamRequest: Equatable, Sendable {
    let board: String
    let since: Int

    var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "board", value: board),
            URLQueryItem(name: "since", value: String(max(0, since)))
        ]
    }
}

struct KanbanEventsEnvelope: Decodable, Equatable, Sendable {
    let events: [KanbanEvent]?
    let cursor: Int?
    let latestEventID: Int?
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case events, cursor, readOnly
        case latestEventID = "latestEventId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try? container.decodeIfPresent([KanbanEvent].self, forKey: .events)
        cursor = container.decodeLossyIntIfPresent(forKey: .cursor)
        latestEventID = container.decodeLossyIntIfPresent(forKey: .latestEventID)
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
    }
}

struct KanbanEvent: Decodable, Equatable, Sendable {
    let eventID: Int?
    let cardID: String?
    let runID: String?
    let kind: String?
    let createdAt: Int?

    enum CodingKeys: String, CodingKey {
        case eventID = "id"
        case cardID = "taskId"
        case runID = "runId"
        case kind, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = container.decodeLossyIntIfPresent(forKey: .eventID)
        cardID = container.decodeLossyStringIfPresent(forKey: .cardID)
        runID = container.decodeLossyStringIfPresent(forKey: .runID)
        kind = container.decodeLossyStringIfPresent(forKey: .kind)
        createdAt = container.decodeLossyIntIfPresent(forKey: .createdAt)
        // Payload values are intentionally not retained: live browsing only needs
        // identity + cursor to reconcile authoritative state, and payloads must
        // never leak through diagnostics.
    }
}

struct KanbanBoardRequest: Equatable, Sendable {
    let board: String
    var tenant: String?
    var assignee: String?
    var includeArchived: Bool
    var onlyMine: Bool
    var since: Int?

    init(
        board: String,
        tenant: String? = nil,
        assignee: String? = nil,
        includeArchived: Bool = false,
        onlyMine: Bool = false,
        since: Int? = nil
    ) {
        self.board = board
        self.tenant = tenant
        self.assignee = assignee
        self.includeArchived = includeArchived
        self.onlyMine = onlyMine
        self.since = since
    }

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "board", value: board)]
        if let tenant, !tenant.isEmpty {
            items.append(URLQueryItem(name: "tenant", value: tenant))
        }
        if let assignee, !assignee.isEmpty {
            items.append(URLQueryItem(name: "assignee", value: assignee))
        }
        if includeArchived {
            items.append(URLQueryItem(name: "include_archived", value: "true"))
        }
        if onlyMine {
            items.append(URLQueryItem(name: "only_mine", value: "true"))
        }
        if let since {
            items.append(URLQueryItem(name: "since", value: String(since)))
        }
        return items
    }
}

/// Tolerant read-only boundary for the independently-versioned Kanban bridge.
/// Every upstream field stays optional so an added or renamed server field never
/// prevents the rest of the shell from decoding.
struct KanbanConfiguration: Decodable, Equatable, Sendable {
    let columns: [String]?
    let assignees: [String]?
    let defaultTenant: String?
    let laneByProfile: Bool?
    let includeArchivedByDefault: Bool?
    let renderMarkdown: Bool?
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case columns, assignees, defaultTenant, laneByProfile, includeArchivedByDefault, renderMarkdown, readOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = try? container.decodeIfPresent([String].self, forKey: .columns)
        assignees = try? container.decodeIfPresent([String].self, forKey: .assignees)
        defaultTenant = container.decodeLossyStringIfPresent(forKey: .defaultTenant)
        laneByProfile = container.decodeLossyBoolIfPresent(forKey: .laneByProfile)
        includeArchivedByDefault = container.decodeLossyBoolIfPresent(forKey: .includeArchivedByDefault)
        renderMarkdown = container.decodeLossyBoolIfPresent(forKey: .renderMarkdown)
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
    }
}

struct KanbanBoardsResponse: Decodable, Equatable, Sendable {
    let boards: [KanbanBoard]?
    let current: String?
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case boards, current, readOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        boards = try? container.decodeIfPresent([KanbanBoard].self, forKey: .boards)
        current = container.decodeLossyStringIfPresent(forKey: .current)
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
    }
}

struct KanbanBoard: Decodable, Equatable, Sendable {
    let slug: String?
    let name: String?
    let description: String?
    let icon: String?
    let color: String?
    let isCurrent: Bool?
    let total: Int?
    let counts: [String: Int]?
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case slug, name, description, icon, color, isCurrent, total, counts, readOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = container.decodeLossyStringIfPresent(forKey: .slug)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        description = container.decodeLossyStringIfPresent(forKey: .description)
        icon = container.decodeLossyStringIfPresent(forKey: .icon)
        color = container.decodeLossyStringIfPresent(forKey: .color)
        isCurrent = container.decodeLossyBoolIfPresent(forKey: .isCurrent)
        total = container.decodeLossyIntIfPresent(forKey: .total)
        counts = try? container.decodeIfPresent([String: Int].self, forKey: .counts)
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
    }
}

struct KanbanBoardSnapshot: Decodable, Equatable, Sendable {
    let columns: [KanbanColumn]?
    let tenants: [String]?
    let assignees: [String]?
    let filters: KanbanAppliedFilters?
    let changed: Bool?
    let latestEventID: Int?
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case columns, tenants, assignees, filters, changed, readOnly
        case latestEventID = "latestEventId"
    }

    init(
        columns: [KanbanColumn]?,
        tenants: [String]?,
        assignees: [String]?,
        filters: KanbanAppliedFilters?,
        changed: Bool?,
        latestEventID: Int?,
        readOnly: Bool?
    ) {
        self.columns = columns
        self.tenants = tenants
        self.assignees = assignees
        self.filters = filters
        self.changed = changed
        self.latestEventID = latestEventID
        self.readOnly = readOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = try? container.decodeIfPresent([KanbanColumn].self, forKey: .columns)
        tenants = try? container.decodeIfPresent([String].self, forKey: .tenants)
        assignees = try? container.decodeIfPresent([String].self, forKey: .assignees)
        filters = try? container.decodeIfPresent(KanbanAppliedFilters.self, forKey: .filters)
        changed = container.decodeLossyBoolIfPresent(forKey: .changed)
        latestEventID = container.decodeLossyIntIfPresent(forKey: .latestEventID)
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
    }
}

struct KanbanColumn: Decodable, Equatable, Sendable {
    let name: String?
    let cards: [KanbanCard]?

    enum CodingKeys: String, CodingKey {
        case name
        case cards = "tasks"
    }

    init(name: String?, cards: [KanbanCard]?) {
        self.name = name
        self.cards = cards
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        cards = try? container.decodeIfPresent([KanbanCard].self, forKey: .cards)
    }
}

struct KanbanCard: Decodable, Equatable, Sendable {
    let cardID: String?
    let title: String?
    let status: KanbanStatus?
    let assignee: String?
    let body: String?
    let tenant: String?
    let priority: Int?
    let commentCount: Int?
    let linkCounts: KanbanLinkCounts?
    let ageSeconds: Double?
    let createdAt: String?
    let updatedAt: String?
    let workspaceKind: String?
    let workspacePath: String?
    let skills: [String]?
    let maxRuntimeSeconds: Int?
    let currentRunID: String?
    let claimLock: String?
    let claimExpires: String?
    let workerID: String?

    enum CodingKeys: String, CodingKey {
        case cardID = "id"
        case title, body, tenant, priority, commentCount, linkCounts, ageSeconds
        case status
        case assignee
        case createdAt, updatedAt, workspaceKind, workspacePath, skills, maxRuntimeSeconds
        case currentRunID = "currentRunId"
        case claimLock, claimExpires
        case workerID = "workerPid"
    }

    init(
        cardID: String?,
        title: String?,
        status: KanbanStatus?,
        assignee: String?,
        body: String?,
        tenant: String?,
        priority: Int?,
        commentCount: Int?,
        linkCounts: KanbanLinkCounts?,
        ageSeconds: Double?,
        createdAt: String?,
        updatedAt: String?,
        workspaceKind: String?,
        workspacePath: String?,
        skills: [String]?,
        maxRuntimeSeconds: Int?,
        currentRunID: String?,
        claimLock: String?,
        claimExpires: String?,
        workerID: String?
    ) {
        self.cardID = cardID
        self.title = title
        self.status = status
        self.assignee = assignee
        self.body = body
        self.tenant = tenant
        self.priority = priority
        self.commentCount = commentCount
        self.linkCounts = linkCounts
        self.ageSeconds = ageSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.workspaceKind = workspaceKind
        self.workspacePath = workspacePath
        self.skills = skills
        self.maxRuntimeSeconds = maxRuntimeSeconds
        self.currentRunID = currentRunID
        self.claimLock = claimLock
        self.claimExpires = claimExpires
        self.workerID = workerID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cardID = container.decodeLossyStringIfPresent(forKey: .cardID)
        title = container.decodeLossyStringIfPresent(forKey: .title)
        status = container.decodeLossyStringIfPresent(forKey: .status).map(KanbanStatus.init(rawValue:))
        assignee = container.decodeLossyStringIfPresent(forKey: .assignee)
        body = container.decodeLossyStringIfPresent(forKey: .body)
        tenant = container.decodeLossyStringIfPresent(forKey: .tenant)
        priority = container.decodeLossyIntIfPresent(forKey: .priority)
        commentCount = container.decodeLossyIntIfPresent(forKey: .commentCount)
        linkCounts = try? container.decodeIfPresent(KanbanLinkCounts.self, forKey: .linkCounts)
        ageSeconds = container.decodeLossyDoubleIfPresent(forKey: .ageSeconds)
        createdAt = container.decodeLossyStringIfPresent(forKey: .createdAt)
        updatedAt = container.decodeLossyStringIfPresent(forKey: .updatedAt)
        workspaceKind = container.decodeLossyStringIfPresent(forKey: .workspaceKind)
        workspacePath = container.decodeLossyStringIfPresent(forKey: .workspacePath)
        skills = try? container.decodeIfPresent([String].self, forKey: .skills)
        maxRuntimeSeconds = container.decodeLossyIntIfPresent(forKey: .maxRuntimeSeconds)
        currentRunID = container.decodeLossyStringIfPresent(forKey: .currentRunID)
        claimLock = container.decodeLossyStringIfPresent(forKey: .claimLock)
        claimExpires = container.decodeLossyStringIfPresent(forKey: .claimExpires)
        workerID = container.decodeLossyStringIfPresent(forKey: .workerID)
    }

    var staleness: KanbanStaleness {
        guard let ageSeconds, let status else { return .none }
        switch status.rawValue {
        case "running":
            return ageSeconds >= 3_600 ? .critical : ageSeconds >= 600 ? .warning : .none
        case "ready":
            return ageSeconds >= 3_600 ? .warning : .none
        case "blocked":
            return ageSeconds >= 86_400 ? .critical : ageSeconds >= 3_600 ? .warning : .none
        default:
            return .none
        }
    }

    func replacingStatus(_ status: String) -> KanbanCard {
        KanbanCard(
            cardID: cardID,
            title: title,
            status: KanbanStatus(rawValue: status),
            assignee: assignee,
            body: body,
            tenant: tenant,
            priority: priority,
            commentCount: commentCount,
            linkCounts: linkCounts,
            ageSeconds: ageSeconds,
            createdAt: createdAt,
            updatedAt: updatedAt,
            workspaceKind: workspaceKind,
            workspacePath: workspacePath,
            skills: skills,
            maxRuntimeSeconds: maxRuntimeSeconds,
            currentRunID: status == "running" ? currentRunID : nil,
            claimLock: status == "running" ? claimLock : nil,
            claimExpires: status == "running" ? claimExpires : nil,
            workerID: status == "running" ? workerID : nil
        )
    }
}

struct KanbanCardDetailEnvelope: Decodable, Equatable, Sendable {
    let card: KanbanCard?
    let comments: [KanbanComment]?
    let events: [KanbanDetailEvent]?
    let links: KanbanDependencyLinks?
    let runs: [KanbanDispatchRun]?
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case card = "task"
        case comments, events, links, runs, readOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        card = try? container.decodeIfPresent(KanbanCard.self, forKey: .card)
        comments = try? container.decodeIfPresent([KanbanComment].self, forKey: .comments)
        events = try? container.decodeIfPresent([KanbanDetailEvent].self, forKey: .events)
        links = try? container.decodeIfPresent(KanbanDependencyLinks.self, forKey: .links)
        runs = try? container.decodeIfPresent([KanbanDispatchRun].self, forKey: .runs)
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
    }
}

struct KanbanCardMutationEnvelope: Decodable, Equatable, Sendable {
    let card: KanbanCard?
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case card = "task"
        case readOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        card = try? container.decodeIfPresent(KanbanCard.self, forKey: .card)
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
    }
}

struct KanbanDependencyMutationEnvelope: Decodable, Equatable, Sendable {
    let ok: Bool?
    let changed: Bool?
    let prerequisiteID: String?
    let dependentID: String?
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, changed, readOnly
        case prerequisiteID = "parentId"
        case dependentID = "childId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        changed = container.decodeLossyBoolIfPresent(forKey: .changed)
        prerequisiteID = container.decodeLossyStringIfPresent(forKey: .prerequisiteID)
        dependentID = container.decodeLossyStringIfPresent(forKey: .dependentID)
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
    }
}

enum KanbanDependencyMutationValidator {
    static func validate(
        _ envelope: KanbanDependencyMutationEnvelope,
        request: KanbanDependencyMutationRequest
    ) throws {
        guard envelope.ok == true,
              normalized(envelope.prerequisiteID) == normalized(request.prerequisiteID),
              normalized(envelope.dependentID) == normalized(request.dependentID) else {
            throw KanbanContractViolation.missingCardIdentity
        }
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum KanbanCardMutationValidator {
    static func validate(_ envelope: KanbanCardMutationEnvelope, expectedCardID: String? = nil) throws -> KanbanCard {
        guard let card = envelope.card,
              let cardID = normalized(card.cardID),
              normalized(card.status?.rawValue) != nil else {
            throw KanbanContractViolation.missingCardIdentity
        }
        if let expectedCardID, cardID != normalized(expectedCardID) {
            throw KanbanContractViolation.missingCardIdentity
        }
        return card
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct KanbanComment: Decodable, Equatable, Sendable {
    let commentID: String?
    let cardID: String?
    let author: String?
    let body: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case commentID = "id"
        case cardID = "taskId"
        case author, body, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commentID = container.decodeLossyStringIfPresent(forKey: .commentID)
        cardID = container.decodeLossyStringIfPresent(forKey: .cardID)
        author = container.decodeLossyStringIfPresent(forKey: .author)
        body = container.decodeLossyStringIfPresent(forKey: .body)
        createdAt = container.decodeLossyStringIfPresent(forKey: .createdAt)
    }

    var presentationID: String {
        commentID ?? [cardID, author, createdAt, body].compactMap { $0 }.joined(separator: "|")
    }
}

/// Detail events retain only the fields Hermex intentionally presents. Unknown
/// payload keys are discarded so raw server payloads cannot reach diagnostics or
/// generic error UI.
struct KanbanDetailEvent: Decodable, Equatable, Sendable {
    let eventID: String?
    let cardID: String?
    let runID: String?
    let kind: String?
    let createdAt: String?
    let payload: KanbanDetailEventPayload?

    enum CodingKeys: String, CodingKey {
        case eventID = "id"
        case cardID = "taskId"
        case runID, kind, createdAt, payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = container.decodeLossyStringIfPresent(forKey: .eventID)
        cardID = container.decodeLossyStringIfPresent(forKey: .cardID)
        runID = container.decodeLossyStringIfPresent(forKey: .runID)
        kind = container.decodeLossyStringIfPresent(forKey: .kind)
        createdAt = container.decodeLossyStringIfPresent(forKey: .createdAt)
        payload = try? container.decodeIfPresent(KanbanDetailEventPayload.self, forKey: .payload)
    }

    var presentationID: String {
        eventID ?? [cardID, runID, kind, createdAt].compactMap { $0 }.joined(separator: "|")
    }
}

struct KanbanDetailEventPayload: Decodable, Equatable, Sendable {
    let status: String?
    let reason: String?
    let summary: String?
    let fields: [String]?

    enum CodingKeys: String, CodingKey { case status, reason, summary, fields }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeLossyStringIfPresent(forKey: .status)
        reason = container.decodeLossyStringIfPresent(forKey: .reason)
        summary = container.decodeLossyStringIfPresent(forKey: .summary)
        fields = try? container.decodeIfPresent([String].self, forKey: .fields)
    }
}

struct KanbanDependencyLinks: Decodable, Equatable, Sendable {
    let prerequisites: [String]?
    let dependents: [String]?

    enum CodingKeys: String, CodingKey {
        case prerequisites = "parents"
        case dependents = "children"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prerequisites = try? container.decodeIfPresent([String].self, forKey: .prerequisites)
        dependents = try? container.decodeIfPresent([String].self, forKey: .dependents)
    }
}

struct KanbanDispatchRun: Decodable, Equatable, Sendable {
    let runID: String?
    let status: String?
    let outcome: String?
    let summary: String?
    let error: String?
    let startedAt: String?
    let finishedAt: String?
    let workerID: String?
    let logTail: String?

    enum CodingKeys: String, CodingKey {
        case runID = "id"
        case alternateRunID = "runId"
        case status, outcome, summary, error, startedAt, finishedAt
        case workerID = "worker"
        case logTail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = container.decodeLossyStringIfPresent(forKey: .runID)
            ?? container.decodeLossyStringIfPresent(forKey: .alternateRunID)
        status = container.decodeLossyStringIfPresent(forKey: .status)
        outcome = container.decodeLossyStringIfPresent(forKey: .outcome)
        summary = container.decodeLossyStringIfPresent(forKey: .summary)
        error = container.decodeLossyStringIfPresent(forKey: .error)
        startedAt = container.decodeLossyStringIfPresent(forKey: .startedAt)
        finishedAt = container.decodeLossyStringIfPresent(forKey: .finishedAt)
        workerID = container.decodeLossyStringIfPresent(forKey: .workerID)
        logTail = container.decodeLossyStringIfPresent(forKey: .logTail)
    }

    var presentationID: String {
        runID ?? [status, outcome, startedAt, finishedAt].compactMap { $0 }.joined(separator: "|")
    }

}

struct KanbanWorkerLog: Decodable, Equatable, Sendable {
    let cardID: String?
    let exists: Bool?
    let sizeBytes: Int?
    let content: String?
    let truncated: Bool?

    enum CodingKeys: String, CodingKey {
        case cardID = "taskId"
        case exists, sizeBytes, content, truncated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cardID = container.decodeLossyStringIfPresent(forKey: .cardID)
        exists = container.decodeLossyBoolIfPresent(forKey: .exists)
        sizeBytes = container.decodeLossyIntIfPresent(forKey: .sizeBytes)
        content = container.decodeLossyStringIfPresent(forKey: .content)
        truncated = container.decodeLossyBoolIfPresent(forKey: .truncated)
        // The upstream `path` field is deliberately not retained.
    }
}

struct KanbanAddCommentResponse: Decodable, Equatable, Sendable {
    let ok: Bool?
    let commentID: String?
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, readOnly
        case commentID = "commentId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        commentID = container.decodeLossyStringIfPresent(forKey: .commentID)
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
    }
}

enum KanbanCardDetailValidator {
    static func validate(_ envelope: KanbanCardDetailEnvelope, requestedCardID: String) throws {
        guard let cardID = normalized(envelope.card?.cardID), cardID == normalized(requestedCardID) else {
            throw KanbanContractViolation.missingCardIdentity
        }
        guard normalized(envelope.card?.status?.rawValue) != nil else {
            throw KanbanContractViolation.missingCardStatus
        }
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct KanbanLinkCounts: Decodable, Equatable, Sendable {
    let parents: Int?
    let children: Int?

    enum CodingKeys: String, CodingKey { case parents, children }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parents = container.decodeLossyIntIfPresent(forKey: .parents)
        children = container.decodeLossyIntIfPresent(forKey: .children)
    }
}

struct KanbanAppliedFilters: Decodable, Equatable, Sendable {
    let tenant: String?
    let assignee: String?
    let includeArchived: Bool?
    let onlyMine: Bool?
    let profile: String?

    enum CodingKeys: String, CodingKey { case tenant, assignee, includeArchived, onlyMine, profile }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tenant = container.decodeLossyStringIfPresent(forKey: .tenant)
        assignee = container.decodeLossyStringIfPresent(forKey: .assignee)
        includeArchived = container.decodeLossyBoolIfPresent(forKey: .includeArchived)
        onlyMine = container.decodeLossyBoolIfPresent(forKey: .onlyMine)
        profile = container.decodeLossyStringIfPresent(forKey: .profile)
    }
}

struct KanbanStats: Decodable, Equatable, Sendable {
    let total: Int?
    let byStatus: [String: Int]?
    let byAssignee: [String: Int]?

    enum CodingKeys: String, CodingKey { case total, byStatus, byAssignee }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = container.decodeLossyIntIfPresent(forKey: .total)
        byStatus = try? container.decodeIfPresent([String: Int].self, forKey: .byStatus)
        byAssignee = try? container.decodeIfPresent([String: Int].self, forKey: .byAssignee)
    }
}

struct KanbanAssigneeHistory: Decodable, Equatable, Sendable {
    let assignees: [String]?

    enum CodingKeys: String, CodingKey { case assignees }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assignees = try? container.decodeIfPresent([String].self, forKey: .assignees)
    }
}

enum KanbanStaleness: Equatable, Sendable {
    case none
    case warning
    case critical
}

/// Retains an unknown server Status rather than turning it into a decoding
/// failure. Future mutation slices can use `isSupported` to keep it read-only.
struct KanbanStatus: Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var isSupported: Bool {
        ["triage", "todo", "blocked", "ready", "running", "done", "archived"].contains(rawValue.lowercased())
    }
}

struct KanbanCompatibilityReport: Equatable, Sendable {
    let board: KanbanBoard
    let warnings: [KanbanCompatibilityWarning]

    var isPartial: Bool { !warnings.isEmpty }
}

enum KanbanCompatibilityWarning: Equatable, Sendable {
    case readOnly
    case writeCapabilityUnavailable
    case unsupportedStatus(String)
}

enum KanbanContractViolation: Error, Equatable, LocalizedError, Sendable {
    case missingConfigurationColumns
    case missingCurrentBoard
    case missingBoardIdentity
    case missingBoardSnapshot
    case missingColumnStatus
    case missingCardIdentity
    case missingCardStatus

    var errorDescription: String? {
        String(localized: "This server's Kanban response is incompatible with Hermex.")
    }
}

enum KanbanResponseError: Error, Equatable, LocalizedError, Sendable {
    case nonJSONContentType

    var errorDescription: String? {
        String(localized: "This server's Kanban response is incompatible with Hermex.")
    }
}

enum KanbanCompatibilityValidator {
    static func validate(
        configuration: KanbanConfiguration,
        boardsResponse: KanbanBoardsResponse,
        snapshot: KanbanBoardSnapshot
    ) throws -> KanbanCompatibilityReport {
        let currentBoardSlug = try nonEmpty(boardsResponse.current, missing: .missingCurrentBoard)
        return try validate(
            configuration: configuration,
            boardsResponse: boardsResponse,
            boardSlug: currentBoardSlug,
            snapshot: snapshot
        )
    }

    static func validate(
        configuration: KanbanConfiguration,
        boardsResponse: KanbanBoardsResponse,
        boardSlug: String,
        snapshot: KanbanBoardSnapshot
    ) throws -> KanbanCompatibilityReport {
        let configuredStatuses = try nonEmptyValues(configuration.columns, missing: .missingConfigurationColumns)
        let selectedBoardSlug = try nonEmpty(boardSlug, missing: .missingBoardIdentity)
        let boards = boardsResponse.boards ?? []
        guard let board = boards.first(where: { normalized($0.slug) == selectedBoardSlug }) else {
            throw KanbanContractViolation.missingBoardIdentity
        }
        guard snapshot.changed == true, let columns = snapshot.columns, !columns.isEmpty else {
            throw KanbanContractViolation.missingBoardSnapshot
        }

        var warnings: [KanbanCompatibilityWarning] = []
        if configuration.readOnly == true || boardsResponse.readOnly == true || snapshot.readOnly == true {
            warnings.append(.readOnly)
        }
        if configuration.readOnly == nil || boardsResponse.readOnly == nil || snapshot.readOnly == nil {
            warnings.append(.writeCapabilityUnavailable)
        }

        for column in columns {
            let status = try nonEmpty(column.name, missing: .missingColumnStatus)
            for card in column.cards ?? [] {
                _ = try nonEmpty(card.cardID, missing: .missingCardIdentity)
                let cardStatus = try nonEmpty(card.status?.rawValue, missing: .missingCardStatus)
                if !configuredStatuses.contains(cardStatus), !warnings.contains(.unsupportedStatus(cardStatus)) {
                    warnings.append(.unsupportedStatus(cardStatus))
                }
            }
            if !configuredStatuses.contains(status), !warnings.contains(.unsupportedStatus(status)) {
                warnings.append(.unsupportedStatus(status))
            }
        }

        return KanbanCompatibilityReport(board: board, warnings: warnings)
    }

    private static func nonEmptyValues(
        _ values: [String]?,
        missing: KanbanContractViolation
    ) throws -> Set<String> {
        let normalizedValues = Set((values ?? []).compactMap(normalized))
        guard !normalizedValues.isEmpty else { throw missing }
        return normalizedValues
    }

    private static func nonEmpty(_ value: String?, missing: KanbanContractViolation) throws -> String {
        guard let normalized = normalized(value) else { throw missing }
        return normalized
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
