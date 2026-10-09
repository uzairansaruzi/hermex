import Foundation

public struct WatchPhoneServerAccount: Sendable, Equatable {
    public let urlString: String
    public let displayName: String
    /// The phone refuses a watch reply for this server. Webui leaves it false.
    public let writesUnsupported: Bool

    public init(urlString: String, displayName: String, writesUnsupported: Bool = false) {
        self.urlString = urlString
        self.displayName = displayName
        self.writesUnsupported = writesUnsupported
    }
}

public struct WatchPhoneSessionRow: Sendable, Equatable {
    public let sessionID: String
    public let title: String
    public let profile: String?
    public let workspaceLabel: String?
    public let updatedAt: Date?
    public let isPinned: Bool
    public let isArchived: Bool
    public let attention: Bool
    public let runState: WatchRunPhase?

    public init(
        sessionID: String,
        title: String,
        profile: String?,
        workspaceLabel: String?,
        updatedAt: Date?,
        isPinned: Bool,
        isArchived: Bool,
        attention: Bool,
        runState: WatchRunPhase?
    ) {
        self.sessionID = sessionID
        self.title = title
        self.profile = profile
        self.workspaceLabel = workspaceLabel
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.attention = attention
        self.runState = runState
    }
}

public struct WatchPhoneTranscriptPage: Sendable, Equatable {
    public struct Block: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case text(role: WatchMessageRole, text: String)
            case code(language: String?, text: String, isTruncated: Bool)
            case tool(title: String, state: String, summary: String?)
            case image(path: String?, mime: String?, alt: String?)
            case unsupported(kind: String, summary: String)
        }

        public let id: String
        public let kind: Kind

        public init(id: String, kind: Kind) {
            self.id = id
            self.kind = kind
        }

        public init(id: String, role: WatchMessageRole, text: String) {
            self.init(id: id, kind: .text(role: role, text: text))
        }
    }

    public let blocks: [Block]
    public let nextBefore: Int?
    public let isTruncated: Bool

    public init(blocks: [Block], nextBefore: Int?, isTruncated: Bool) {
        self.blocks = blocks
        self.nextBefore = nextBefore
        self.isTruncated = isTruncated
    }
}

public struct WatchPhoneAttachmentHint: Sendable, Equatable {
    public let name: String
    public let path: String?
    public let mime: String?
    public let isImage: Bool

    public init(name: String, path: String?, mime: String?, isImage: Bool) {
        self.name = name
        self.path = path
        self.mime = mime
        self.isImage = isImage
    }
}

public struct WatchPhoneToolHint: Sendable, Equatable {
    public let title: String
    public let state: String
    public let summary: String?

    public init(title: String, state: String, summary: String?) {
        self.title = title
        self.state = state
        self.summary = summary
    }
}

public struct WatchPhoneMessageHint: Sendable, Equatable {
    public let id: String
    public let role: WatchMessageRole
    public let text: String
    public let attachments: [WatchPhoneAttachmentHint]
    public let tools: [WatchPhoneToolHint]
    public let isToolResult: Bool

    public init(
        id: String,
        role: WatchMessageRole,
        text: String,
        attachments: [WatchPhoneAttachmentHint] = [],
        tools: [WatchPhoneToolHint] = [],
        isToolResult: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.tools = tools
        self.isToolResult = isToolResult
    }
}

/// Display attachment the iPhone already uploaded. Same fields `startChat`
/// sends for an iOS voice note (`PendingAttachment.toJSONValue`).
public struct WatchChatAttachment: Sendable, Equatable {
    public let name: String
    public let path: String
    public let mime: String
    public let size: Int?
    public let isImage: Bool

    public init(name: String, path: String, mime: String, size: Int?, isImage: Bool) {
        self.name = name
        self.path = path
        self.mime = mime
        self.size = size
        self.isImage = isImage
    }
}

/// Phone-owned execution. The broker never talks to `hermes-webui` itself.
public protocol WatchPhoneBackend: Sendable {
    func servers() async -> [WatchPhoneServerAccount]
    func listSessions(urlString: String, archived: Bool, query: String?, limit: Int) async throws -> [WatchPhoneSessionRow]
    func createSession(urlString: String, profileID: String?, workspace: String?) async throws -> String
    func startChat(urlString: String, sessionID: String, message: String) async throws -> String
    func startChat(
        urlString: String,
        sessionID: String,
        message: String,
        attachments: [WatchChatAttachment]?
    ) async throws -> String
    func uploadFile(
        urlString: String,
        sessionID: String,
        data: Data,
        filename: String
    ) async throws -> WatchChatAttachment
    func cancelChat(urlString: String, streamID: String) async throws
    func transcript(urlString: String, sessionID: String, before: Int?, limit: Int) async throws -> WatchPhoneTranscriptPage
    func runPhase(urlString: String, sessionID: String, streamID: String) async throws -> (phase: WatchRunPhase, isTerminal: Bool)
    func transcribeAudio(urlString: String, data: Data, filename: String) async throws -> String
    func mediaData(urlString: String, sessionID: String, path: String) async throws -> Data
    func listProfiles(urlString: String) async throws -> WatchPhoneProfilePage
    func switchProfile(urlString: String, name: String) async throws
    func listTasks(urlString: String, limit: Int) async throws -> [WatchPhoneTaskGlance]
    func listSkills(urlString: String, query: String?, limit: Int) async throws -> [WatchPhoneSkillGlance]
    func memoryGlance(urlString: String) async throws -> [WatchPhoneMemoryGlance]
    func usageGlance(urlString: String, days: Int) async throws -> WatchPhoneUsageGlance
    func listProjects(urlString: String, limit: Int) async throws -> [WatchPhoneProjectGlance]
    func listKanbanCards(urlString: String, limit: Int) async throws -> [WatchPhoneKanbanCardGlance]
    func listKanbanBoard(
        urlString: String,
        slug: String?,
        includeArchived: Bool,
        onlyMine: Bool,
        limit: Int
    ) async throws -> WatchPhoneKanbanBoardGlance
    func createKanbanCard(urlString: String, boardSlug: String, title: String, status: String) async throws
    func dispatchKanban(urlString: String, boardSlug: String, dryRun: Bool) async throws -> String
    func listTaskRuns(urlString: String, jobID: String, limit: Int) async throws -> [WatchPhoneTaskRun]
    func taskRunOutput(urlString: String, jobID: String, runID: String) async throws -> String?
    func controlTask(urlString: String, jobID: String, action: String) async throws
    func setSkillEnabled(urlString: String, name: String, enabled: Bool) async throws
    func moveKanbanCard(urlString: String, cardID: String, status: String, boardSlug: String) async throws
}

/// `skills` query the phone treats as a Kanban board read. Any other query
/// stays a skill-name filter. A board switch or filter appends the slug and
/// the two iPhone toggles after the marker.
public enum WatchGlanceQuery {
    public static let kanban = "hermex-glance:kanban"

    public static func kanban(slug: String?, includeArchived: Bool, onlyMine: Bool) -> String {
        [kanban, slug ?? "", includeArchived ? "1" : "0", onlyMine ? "1" : "0"].joined(separator: "\u{1e}")
    }

    public static func kanbanRequest(from query: String?) -> (slug: String?, includeArchived: Bool, onlyMine: Bool)? {
        guard let query else { return nil }
        guard query == kanban || query.hasPrefix(kanban + "\u{1e}") else { return nil }
        guard query != kanban else { return (nil, false, false) }
        let parts = query.split(separator: "\u{1e}", omittingEmptySubsequences: false).map(String.init)
        let slug = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        return (slug, parts.count > 2 && parts[2] == "1", parts.count > 3 && parts[3] == "1")
    }
}

/// The board the watch is browsing, plus the other boards it can switch to.
/// Travels as one reserved row in the Kanban skill read.
public struct WatchKanbanBoardChrome: Codable, Hashable, Sendable {
    public static let cardID = "kanban.board"

    public var name: String
    public var slug: String
    public var columns: [String]
    public var boards: [Choice]
    /// `"webui"` or `"hermes"`. Absent on glances from a phone that predates the
    /// field; the watch then keeps webui destinations.
    public var movePolicy: String?

    public var resolvedMovePolicy: WatchKanbanMovePolicy {
        WatchKanbanMovePolicy(rawValue: movePolicy ?? "") ?? .webui
    }

    public struct Choice: Codable, Hashable, Sendable {
        public var slug: String
        public var name: String

        public init(slug: String, name: String) {
            self.slug = slug
            self.name = name
        }
    }

    public init(name: String, slug: String, columns: [String], boards: [Choice], movePolicy: String? = nil) {
        self.name = name
        self.slug = slug
        self.columns = columns
        self.boards = boards
        self.movePolicy = movePolicy
    }

    public static var placeholder: WatchKanbanBoardChrome {
        WatchKanbanBoardChrome(name: "Kanban", slug: "", columns: WatchKanbanStatus.boardOrder, boards: [])
    }

    public var wireSummary: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    public init?(wireSummary: String) {
        guard let data = wireSummary.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              !value.columns.isEmpty
        else { return nil }
        self = value
    }
}

public struct WatchPhoneProfileChoice: Sendable, Equatable {
    public let name: String
    public let label: String

    public init(name: String, label: String) {
        self.name = name
        self.label = label
    }
}

public struct WatchPhoneProfilePage: Sendable, Equatable {
    public let profiles: [WatchPhoneProfileChoice]
    public let activeName: String?

    public init(profiles: [WatchPhoneProfileChoice], activeName: String?) {
        self.profiles = profiles
        self.activeName = activeName
    }
}

public struct WatchPhoneTaskGlance: Sendable, Equatable {
    public let id: String
    public let name: String
    public let schedule: String
    public let enabled: Bool
    public let running: Bool
    public let lastResult: String?
    public let lastRunAt: Date?
    public let nextRunAt: Date?
    public let failureSummary: String?

    public init(
        id: String,
        name: String,
        schedule: String,
        enabled: Bool,
        running: Bool,
        lastResult: String?,
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        failureSummary: String? = nil
    ) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.enabled = enabled
        self.running = running
        self.lastResult = lastResult
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.failureSummary = failureSummary
    }
}

/// One past run from the task's history. Upstream records only when the run's
/// output file was written, plus optional usage scraped from its front matter.
public struct WatchPhoneTaskRun: Sendable, Equatable {
    public let id: String
    public let finishedAt: Date?
    public let durationSeconds: Double?

    public init(id: String, finishedAt: Date?, durationSeconds: Double?) {
        self.id = id
        self.finishedAt = finishedAt
        self.durationSeconds = durationSeconds
    }
}

public struct WatchPhoneSkillGlance: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let enabled: Bool?

    public init(name: String, summary: String, enabled: Bool?) {
        self.name = name
        self.summary = summary
        self.enabled = enabled
    }
}

/// `text` is already wrist-shaped (`WatchMemoryProjection.wireContent`).
public struct WatchPhoneMemoryGlance: Sendable, Equatable {
    public let section: String
    public let text: String
    public let isTruncated: Bool

    public init(section: String, text: String, isTruncated: Bool = false) {
        self.section = section
        self.text = text
        self.isTruncated = isTruncated
    }
}

public struct WatchPhoneModelUsage: Sendable, Equatable {
    public let name: String
    public let totalTokens: Int
    public let cost: Double
    public let sessions: Int

    public init(name: String, totalTokens: Int, cost: Double, sessions: Int) {
        self.name = name
        self.totalTokens = totalTokens
        self.cost = cost
        self.sessions = sessions
    }
}

public struct WatchPhoneUsageGlance: Sendable, Equatable {
    public let days: Int
    public let totalSessions: Int
    public let totalMessages: Int
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalTokens: Int
    public let totalCost: Double
    public let models: [String]
    public let modelUsage: [WatchPhoneModelUsage]
    /// Oldest first, input + output tokens per day.
    public let dailyTokens: [Int]

    public init(
        days: Int,
        totalSessions: Int,
        totalMessages: Int,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalTokens: Int,
        totalCost: Double,
        models: [String],
        modelUsage: [WatchPhoneModelUsage] = [],
        dailyTokens: [Int] = []
    ) {
        self.days = days
        self.totalSessions = totalSessions
        self.totalMessages = totalMessages
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.models = models
        self.modelUsage = modelUsage
        self.dailyTokens = dailyTokens
    }
}

public struct WatchPhoneProjectGlance: Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// `status` is the server's status key (`todo`, `running`, …), never a display
/// title: it is what a move sends back.
public struct WatchPhoneKanbanBoardGlance: Sendable, Equatable {
    public var name: String
    public var slug: String
    public var columns: [String]
    public var boards: [WatchKanbanBoardChrome.Choice]
    public var cards: [WatchPhoneKanbanCardGlance]
    /// Raw `WatchKanbanMovePolicy` carried onto the glance the watch already reads.
    public var movePolicy: String?

    public init(
        name: String,
        slug: String,
        columns: [String],
        boards: [WatchKanbanBoardChrome.Choice],
        cards: [WatchPhoneKanbanCardGlance],
        movePolicy: String? = nil
    ) {
        self.name = name
        self.slug = slug
        self.columns = columns
        self.boards = boards
        self.cards = cards
        self.movePolicy = movePolicy
    }
}

public struct WatchPhoneKanbanCardGlance: Sendable, Equatable {
    public let id: String
    public let title: String
    public let status: String
    public let assignee: String?
    public let priority: Int?
    public let body: String?
    public let tenant: String?
    public let commentCount: Int?
    public let linkCount: Int?
    public let ageSeconds: Double?
    public let skills: [String]?

    public init(
        id: String,
        title: String,
        status: String,
        assignee: String? = nil,
        priority: Int? = nil,
        body: String? = nil,
        tenant: String? = nil,
        commentCount: Int? = nil,
        linkCount: Int? = nil,
        ageSeconds: Double? = nil,
        skills: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.assignee = assignee
        self.priority = priority
        self.body = body
        self.tenant = tenant
        self.commentCount = commentCount
        self.linkCount = linkCount
        self.ageSeconds = ageSeconds
        self.skills = skills
    }
}

public extension WatchPhoneBackend {
    func startChat(
        urlString: String,
        sessionID: String,
        message: String,
        attachments: [WatchChatAttachment]?
    ) async throws -> String {
        try await startChat(urlString: urlString, sessionID: sessionID, message: message)
    }

    func uploadFile(
        urlString: String,
        sessionID: String,
        data: Data,
        filename: String
    ) async throws -> WatchChatAttachment {
        throw WatchCompanionError.backend(.invalidResponse)
    }

    func mediaData(urlString: String, sessionID: String, path: String) async throws -> Data {
        throw WatchCompanionError.unsupported(.media)
    }

    func listProfiles(urlString: String) async throws -> WatchPhoneProfilePage {
        throw WatchCompanionError.unsupported(.composerOptions)
    }

    func switchProfile(urlString: String, name: String) async throws {
        throw WatchCompanionError.unsupported(.composerOptions)
    }

    func listTasks(urlString: String, limit: Int) async throws -> [WatchPhoneTaskGlance] {
        throw WatchCompanionError.unsupported(.tasks)
    }

    func listSkills(urlString: String, query: String?, limit: Int) async throws -> [WatchPhoneSkillGlance] {
        throw WatchCompanionError.unsupported(.skills)
    }

    func memoryGlance(urlString: String) async throws -> [WatchPhoneMemoryGlance] {
        throw WatchCompanionError.unsupported(.memoryDocument)
    }

    func usageGlance(urlString: String, days: Int) async throws -> WatchPhoneUsageGlance {
        throw WatchCompanionError.unsupported(.insightsAggregate)
    }

    func listProjects(urlString: String, limit: Int) async throws -> [WatchPhoneProjectGlance] {
        throw WatchCompanionError.unsupported(.workspace)
    }

    func listKanbanCards(urlString: String, limit: Int) async throws -> [WatchPhoneKanbanCardGlance] {
        throw WatchCompanionError.unsupported(.tasks)
    }

    func listKanbanBoard(
        urlString: String,
        slug: String?,
        includeArchived: Bool,
        onlyMine: Bool,
        limit: Int
    ) async throws -> WatchPhoneKanbanBoardGlance {
        let cards = try await listKanbanCards(urlString: urlString, limit: limit)
        return WatchPhoneKanbanBoardGlance(
            name: "Board",
            slug: slug ?? "",
            columns: WatchKanbanStatus.boardOrder,
            boards: [],
            cards: cards
        )
    }

    func createKanbanCard(urlString: String, boardSlug: String, title: String, status: String) async throws {
        throw WatchCompanionError.unsupported(.tasks)
    }

    func dispatchKanban(urlString: String, boardSlug: String, dryRun: Bool) async throws -> String {
        throw WatchCompanionError.unsupported(.tasks)
    }

    func listTaskRuns(urlString: String, jobID: String, limit: Int) async throws -> [WatchPhoneTaskRun] {
        throw WatchCompanionError.unsupported(.taskRuns)
    }

    func taskRunOutput(urlString: String, jobID: String, runID: String) async throws -> String? {
        throw WatchCompanionError.unsupported(.taskRunDetail)
    }

    func controlTask(urlString: String, jobID: String, action: String) async throws {
        throw WatchCompanionError.unsupported(.tasks)
    }

    func setSkillEnabled(urlString: String, name: String, enabled: Bool) async throws {
        throw WatchCompanionError.unsupported(.skills)
    }

    func moveKanbanCard(urlString: String, cardID: String, status: String, boardSlug: String) async throws {
        throw WatchCompanionError.unsupported(.tasks)
    }
}
