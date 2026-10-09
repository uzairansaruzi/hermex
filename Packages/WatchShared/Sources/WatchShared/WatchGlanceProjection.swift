import Foundation

// Phone-side shaping for the read-mostly glances. Same rule as the transcript:
// the phone clips and normalizes to wrist size, the watch only styles.

// MARK: - Memory

/// Hermes memory files (`MEMORY.md`, `USER.md`) store one fact per entry,
/// separated by a line holding only `§`. The watch shows each entry as its own
/// row, so the delimiter never reaches the screen.
public enum WatchMemoryProjection {
    public static let maximumEntries = 40
    public static let maximumEntryCharacters = 500
    /// Total budget per section, well under the 16 KiB DTO cap and the
    /// WatchConnectivity message size with two sections in one reply.
    public static let maximumSectionCharacters = 4_000
    static let delimiter = "§"

    /// Splits stored memory into trimmed, non-empty entries. Tolerant of
    /// content with no delimiter (one entry) and of `\r\n` line endings, so the
    /// watch can run it over whatever the phone sent.
    public static func entries(in content: String) -> [String] {
        var entries: [String] = []
        var current: [String] = []

        func flush() {
            let entry = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !entry.isEmpty { entries.append(entry) }
            current = []
        }

        for line in content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == delimiter {
                flush()
            } else {
                current.append(line)
            }
        }
        flush()
        return entries
    }

    /// Phone side: entries normalized to wrist Markdown and clipped, plus
    /// whether anything was shortened or dropped.
    public static func wristEntries(from raw: String) -> (entries: [String], isTruncated: Bool) {
        var result: [String] = []
        var used = 0
        var isTruncated = false
        for entry in entries(in: raw) {
            guard result.count < maximumEntries, used < maximumSectionCharacters else {
                isTruncated = true
                break
            }
            let normalized = WatchTranscriptProjection.wristMarkdown(entry)
            let budget = min(maximumEntryCharacters, maximumSectionCharacters - used)
            let clipped = WatchTranscriptProjection.clippedMarkdown(normalized, max: budget)
            guard let clipped else { continue }
            if clipped.count < normalized.count { isTruncated = true }
            result.append(clipped)
            used += clipped.count
        }
        return (result, isTruncated)
    }

    /// Wire form of one section: entries joined by delimiter lines, which
    /// `entries(in:)` splits again on the watch.
    public static func wireContent(_ entries: [String]) -> String {
        entries.joined(separator: "\n\(delimiter)\n")
    }
}

// MARK: - Task runs

public enum WatchTaskRunProjection {
    /// The agent's reply inside a cron output file: everything after the first
    /// `## Response` / `# Response` heading, the same rule upstream's
    /// `_cron_output_snippet` uses, with terminal colour codes removed. Files
    /// without the heading are returned whole.
    public static func responseBody(_ content: String) -> String {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let body: String
        if let index = lines.firstIndex(where: { $0.hasPrefix("## Response") || $0.hasPrefix("# Response") }) {
            body = lines[(index + 1)...].joined(separator: "\n")
        } else {
            body = lines.joined(separator: "\n")
        }
        return body
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Kanban

/// One Kanban Card as the watch shows it. Cards travel inside
/// `WatchSkillSummary.summary` (the `WatchGlanceQuery.kanban` read), so this
/// codec is the single place that knows the line layout.
public struct WatchKanbanCard: Hashable, Sendable, Identifiable {
    public static let maximumTitleCharacters = 200
    public static let maximumBodyCharacters = 400

    public let id: String
    public let title: String
    /// Server status key: `triage`, `todo`, `ready`, `running`, `blocked`, `done`.
    public let status: String
    public let assignee: String?
    public let priority: Int?
    public let body: String?
    public let tenant: String?
    public let commentCount: Int?
    public let linkCount: Int?
    /// Age of the card in seconds, the same clock the iPhone board uses.
    public let ageSeconds: Int?
    public let skills: [String]?

    public init(
        id: String,
        title: String,
        status: String,
        assignee: String?,
        priority: Int?,
        body: String?,
        tenant: String? = nil,
        commentCount: Int? = nil,
        linkCount: Int? = nil,
        ageSeconds: Double? = nil,
        skills: [String]? = nil
    ) {
        self.id = id
        self.title = Self.singleLine(title, max: Self.maximumTitleCharacters) ?? "Card"
        self.status = Self.singleLine(status, max: 64)?.lowercased() ?? "todo"
        self.assignee = Self.singleLine(assignee, max: 64)
        self.priority = priority
        self.body = body.flatMap {
            WatchTranscriptProjection.clippedMarkdown(
                WatchTranscriptProjection.wristMarkdown($0),
                max: Self.maximumBodyCharacters
            )
        }
        self.tenant = Self.singleLine(tenant, max: 64)
        self.commentCount = commentCount.flatMap { $0 > 0 ? $0 : nil }
        self.linkCount = linkCount.flatMap { $0 > 0 ? $0 : nil }
        self.ageSeconds = ageSeconds.flatMap { $0 >= 0 ? Int($0) : nil }
        let cleanedSkills = (skills ?? []).compactMap { Self.singleLine($0, max: 64) }
        self.skills = cleanedSkills.isEmpty ? nil : Array(cleanedSkills.prefix(8))
    }

    /// Same card after a move, so the row keeps the facts the status change
    /// does not touch.
    public func withStatus(_ status: String) -> WatchKanbanCard {
        WatchKanbanCard(
            id: id,
            title: title,
            status: status,
            assignee: assignee,
            priority: priority,
            body: body,
            tenant: tenant,
            commentCount: commentCount,
            linkCount: linkCount,
            ageSeconds: ageSeconds.map(Double.init),
            skills: skills
        )
    }

    public enum Staleness: Equatable, Sendable {
        case none, warning, critical
    }

    /// The iPhone thresholds: Running at 10 minutes and 1 hour, Ready at 1
    /// hour, Blocked at 1 hour and 1 day.
    public var staleness: Staleness {
        guard let ageSeconds else { return .none }
        switch status {
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

    public var ageLabel: String? {
        guard let ageSeconds, ageSeconds >= 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = ageSeconds >= 86_400 ? .day : ageSeconds >= 3_600 ? .hour : .minute
        return formatter.string(from: TimeInterval(ageSeconds))
    }

    /// Header lines, then the body. The body is last because it is the only
    /// field that may itself contain newlines. Older watches wrote title and
    /// status only, or five fields with no marker; both still decode.
    public var wireSummary: String {
        let header = [
            Self.wireMarker,
            title,
            status,
            assignee ?? "",
            priority.map(String.init) ?? "",
            tenant ?? "",
            commentCount.map(String.init) ?? "",
            linkCount.map(String.init) ?? "",
            ageSeconds.map(String.init) ?? "",
            (skills ?? []).joined(separator: ", ")
        ].joined(separator: "\n")
        return header + "\n" + (body ?? "")
    }

    public init(id: String, wireSummary: String) {
        let parts = wireSummary.split(separator: "\n", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
        func part(_ index: Int) -> String? {
            guard parts.indices.contains(index) else { return nil }
            let value = parts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        self.id = id
        if parts.first == Self.wireMarker {
            self.title = part(1) ?? "Card"
            self.status = part(2)?.lowercased() ?? "todo"
            self.assignee = part(3)
            self.priority = part(4).flatMap(Int.init)
            self.tenant = part(5)
            self.commentCount = part(6).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            self.linkCount = part(7).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            self.ageSeconds = part(8).flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
            let skills = part(9)?.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            self.skills = skills?.isEmpty == false ? skills : nil
            self.body = part(10)
            return
        }
        let legacy = wireSummary.split(separator: "\n", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        func legacyPart(_ index: Int) -> String? {
            guard legacy.indices.contains(index) else { return nil }
            let value = legacy[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        self.title = legacyPart(0) ?? "Card"
        self.status = legacyPart(1)?.lowercased() ?? "todo"
        self.assignee = legacyPart(2)
        self.priority = legacyPart(3).flatMap(Int.init)
        self.body = legacyPart(4)
        self.tenant = nil
        self.commentCount = nil
        self.linkCount = nil
        self.ageSeconds = nil
        self.skills = nil
    }

    private static let wireMarker = "kanban.v2"

    private static func singleLine(_ value: String?, max: Int) -> String? {
        guard let value else { return nil }
        let flattened = value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flattened.isEmpty else { return nil }
        if flattened.count <= max { return flattened }
        return String(flattened.prefix(max - 1)) + "…"
    }
}

/// Which move rules a board uses. Missing or unknown values stay on webui,
/// so a glance saved before this field existed still offers today's destinations.
public enum WatchKanbanMovePolicy: String, Sendable, Equatable {
    case webui
    case hermes
}

/// Board vocabulary and the wrist's move policy, mirroring the iPhone's
/// `KanbanFeatureState.moveDestinations` and Complete action.
public enum WatchKanbanStatus {
    /// Upstream `BOARD_COLUMNS` order.
    public static let boardOrder = ["triage", "todo", "ready", "running", "blocked", "done"]

    public static func title(_ status: String) -> String {
        switch status.lowercased() {
        case "triage": return "Triage"
        case "todo": return "To Do"
        case "scheduled": return "Scheduled"
        case "ready": return "Ready"
        case "running": return "Running"
        case "blocked": return "Blocked"
        case "review": return "Review"
        case "done": return "Done"
        case "archived": return "Archived"
        default: return status.isEmpty ? "Unknown" : status.capitalized
        }
    }

    /// Statuses a new Card may start in. A Hermes host only starts in Triage or Ready.
    public static func createDestinations(policy: WatchKanbanMovePolicy? = nil) -> [String] {
        switch policy ?? .webui {
        case .webui: return ["triage", "todo", "ready"]
        case .hermes: return ["triage", "ready"]
        }
    }

    /// Destinations the phone will send. Done is included for Hermes because
    /// Complete is legal from Review; the watch still hides it from every other column.
    public static func allowsDestination(_ status: String, policy: WatchKanbanMovePolicy? = nil) -> Bool {
        switch policy ?? .webui {
        case .webui: return ["triage", "todo", "ready", "done"].contains(status.lowercased())
        case .hermes: return ["triage", "ready", "done"].contains(status.lowercased())
        }
    }

    /// Ordinary moves plus Done, for the board's server. A Hermes host's ordinary
    /// destinations are Triage and Ready. To Do, Scheduled, and Review are never
    /// destinations. Complete is only offered from Review. Running is claimed by
    /// the dispatcher and Blocked needs a reason, so neither is a wrist destination.
    /// Archived Cards are restored on iPhone. A nil policy is webui.
    public static func moveDestinations(from status: String, policy: WatchKanbanMovePolicy? = nil) -> [String] {
        let current = status.lowercased()
        guard current != "archived" else { return [] }
        switch policy ?? .webui {
        case .webui:
            return ["triage", "todo", "ready", "done"].filter { $0 != current }
        case .hermes:
            var destinations = ["triage", "ready"].filter { $0 != current }
            if current == "review" { destinations.append("done") }
            return destinations
        }
    }

    /// Leaving Running may clear the Card's claim and worker state, so the
    /// watch confirms first, like iPhone.
    public static func needsRunningExitConfirmation(from status: String) -> Bool {
        status.lowercased() == "running"
    }
}

// MARK: - Line breaking

/// watchOS hyphenates wrapped text, which splits an email or URL into
/// `gmail.-com`. Zero-width spaces at the token's own boundaries give the line
/// breaker a better place to wrap, so it never invents a hyphen inside one.
public enum WatchTextBreaking {
    static let breakOpportunity: Character = "\u{200B}"

    public static func breakable(_ text: String) -> String {
        guard text.contains(where: { "@/._-".contains($0) }) else { return text }
        var result = ""
        var token = ""

        func flush() {
            result += needsBreaks(token) ? withBreaks(token) : token
            token = ""
        }

        for character in text {
            if character.isWhitespace {
                flush()
                result.append(character)
            } else {
                token.append(character)
            }
        }
        flush()
        return result
    }

    private static func needsBreaks(_ token: String) -> Bool {
        if token.contains("@") || token.contains("://") { return true }
        return token.count >= 14 && token.contains(where: { "/._-".contains($0) })
    }

    /// Break after `@` and `/`, before `.`, `_` and `-`, never at either end.
    private static func withBreaks(_ token: String) -> String {
        let characters = Array(token)
        var result = ""
        for (index, character) in characters.enumerated() {
            let isInterior = index > 0 && index < characters.count - 1
            if isInterior, ".-_".contains(character) {
                result.append(breakOpportunity)
            }
            result.append(character)
            if isInterior, "@/".contains(character) {
                result.append(breakOpportunity)
            }
        }
        return result
    }
}

// MARK: - Clipping

extension WatchTranscriptProjection {
    /// Clips normalized Markdown to `max` characters without leaving a dangling
    /// link or inline-code token. `nil` for blank input.
    public static func clippedMarkdown(_ text: String, max: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, max > 1 else { return nil }
        guard trimmed.count > max else { return trimmed }
        return repairingClippedMarkdown(String(trimmed.prefix(max - 1)) + "…")
    }
}
