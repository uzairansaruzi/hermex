import Foundation

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

    enum CodingKeys: String, CodingKey {
        case cardID = "id"
        case title, body, tenant, priority, commentCount, linkCounts, ageSeconds
        case status
        case assignee
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
