import Foundation

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
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case slug, name, description, icon, color, isCurrent, total, readOnly
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
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
    }
}

struct KanbanBoardSnapshot: Decodable, Equatable, Sendable {
    let columns: [KanbanColumn]?
    let changed: Bool?
    let latestEventID: Int?
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case columns, changed, latestEventID, readOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = try? container.decodeIfPresent([KanbanColumn].self, forKey: .columns)
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

    enum CodingKeys: String, CodingKey {
        case cardID = "id"
        case title
        case status
        case assignee
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cardID = container.decodeLossyStringIfPresent(forKey: .cardID)
        title = container.decodeLossyStringIfPresent(forKey: .title)
        status = container.decodeLossyStringIfPresent(forKey: .status).map(KanbanStatus.init(rawValue:))
        assignee = container.decodeLossyStringIfPresent(forKey: .assignee)
    }
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
        let configuredStatuses = try nonEmptyValues(configuration.columns, missing: .missingConfigurationColumns)
        let currentBoardSlug = try nonEmpty(boardsResponse.current, missing: .missingCurrentBoard)
        let boards = boardsResponse.boards ?? []
        guard let board = boards.first(where: { normalized($0.slug) == currentBoardSlug }) else {
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
