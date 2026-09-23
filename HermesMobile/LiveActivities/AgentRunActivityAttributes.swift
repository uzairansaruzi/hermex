import ActivityKit
import Foundation

struct AgentRunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var sessionID: String
        var sessionTitle: String
        var schemaVersion = 1
        // The wire value stays open-ended; only presentation maps known statuses.
        var rawStatus: String
        var tool: String?
        var toolCalls: Int?
        var status: AgentRunActivityStatus {
            get {
                guard schemaVersion <= 1 else { return .starting }
                switch rawStatus {
                case "running":
                    guard let tool else { return .thinking }
                    switch AgentRunActivitySanitizer.toolKind(name: tool) {
                    case .command: return .runningCommand
                    case .search: return .searchingFiles
                    case .files: return .readingFiles
                    case .generic: return .usingTool
                    }
                case "waiting": return .waiting
                case "done": return .complete
                default: return AgentRunActivityStatus(rawValue: rawStatus) ?? .starting
                }
            }
            set { rawStatus = newValue.rawValue }
        }
        var currentActivity: String
        var responseExcerpt: String
        var startedAt: Date
        var updatedAt: Date
        var isStale: Bool
        var isFinal: Bool
        var errorSummary: String?
        /// A bot's bounded work summary ("Plan 2 of 5", "2 workers"): counts only, never
        /// reply text, so it is safe on a locked phone. Nil for a webui session, and
        /// optional so an activity persisted by an older build still decodes (#489).
        var chips: [String]?

        init(
            sessionID: String,
            sessionTitle: String,
            status: AgentRunActivityStatus,
            currentActivity: String,
            responseExcerpt: String = "",
            startedAt: Date,
            updatedAt: Date,
            isStale: Bool = false,
            isFinal: Bool = false,
            errorSummary: String? = nil
        ) {
            self.sessionID = sessionID
            self.sessionTitle = AgentRunActivitySanitizer.sessionTitle(sessionTitle)
            self.rawStatus = status.rawValue
            self.currentActivity = AgentRunActivitySanitizer.activityLine(currentActivity)
            self.responseExcerpt = AgentRunActivitySanitizer.responseExcerpt(responseExcerpt)
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.isStale = isStale
            self.isFinal = isFinal
            self.errorSummary = errorSummary.map(AgentRunActivitySanitizer.activityLine)
        }

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "v", rawStatus = "status", tool, toolCalls = "tool_calls"
            case pushStartedAt = "started_at"
            case sessionID, sessionTitle, currentActivity, responseExcerpt, startedAt, updatedAt
            case isStale, isFinal, errorSummary, chips
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            rawStatus = try c.decodeIfPresent(String.self, forKey: .rawStatus) ?? "unknown"
            tool = try c.decodeIfPresent(String.self, forKey: .tool)
            toolCalls = try c.decodeIfPresent(Int.self, forKey: .toolCalls)
            sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
            sessionTitle = try c.decodeIfPresent(String.self, forKey: .sessionTitle) ?? ""
            let unixStart = try c.decodeIfPresent(Double.self, forKey: .pushStartedAt)
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
                ?? unixStart.map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            // The compact relay state has no end timestamp. Freeze the final timer
            // at receipt time rather than showing a zero-length completed run.
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
            isStale = try c.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
            isFinal = try c.decodeIfPresent(Bool.self, forKey: .isFinal)
                ?? (schemaVersion <= 1 && ["done", "failed"].contains(rawStatus))
            responseExcerpt = try c.decodeIfPresent(String.self, forKey: .responseExcerpt) ?? ""
            errorSummary = try c.decodeIfPresent(String.self, forKey: .errorSummary)
            chips = try c.decodeIfPresent([String].self, forKey: .chips)
            currentActivity = try c.decodeIfPresent(String.self, forKey: .currentActivity) ?? ""
            if currentActivity.isEmpty {
                if schemaVersion <= 1, rawStatus == "running", let tool,
                   case .generic(let label) = AgentRunActivitySanitizer.toolKind(name: tool) {
                    currentActivity = String(localized: "Using \(label)")
                } else { currentActivity = status.title }
            }
            if schemaVersion > 1 {
                currentActivity = AgentRunActivityStatus.starting.title
                responseExcerpt = ""
                chips = nil
                isFinal = false
            } else if let toolCalls, chips == nil, toolCalls > 0 {
                chips = [String(localized: "\(toolCalls) tools")]
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schemaVersion, forKey: .schemaVersion)
            try c.encode(rawStatus, forKey: .rawStatus)
            try c.encodeIfPresent(tool, forKey: .tool)
            try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encode(sessionTitle, forKey: .sessionTitle)
            try c.encode(currentActivity, forKey: .currentActivity)
            try c.encode(responseExcerpt, forKey: .responseExcerpt)
            try c.encode(startedAt, forKey: .startedAt)
            try c.encode(updatedAt, forKey: .updatedAt)
            try c.encode(isStale, forKey: .isStale)
            try c.encode(isFinal, forKey: .isFinal)
            try c.encodeIfPresent(errorSummary, forKey: .errorSummary)
            try c.encodeIfPresent(chips, forKey: .chips)
        }

        /// Pushes omit identity and freshness flags: immutable attributes and
        /// ActivityKit's stale-date clock supply those to every widget surface.
        func presented(attributes: AgentRunActivityAttributes, systemIsStale: Bool) -> Self {
            var value = self
            if value.sessionID.isEmpty { value.sessionID = attributes.sessionID }
            if value.sessionTitle.isEmpty { value.sessionTitle = attributes.sessionTitle }
            if value.startedAt == .distantPast { value.startedAt = attributes.startedAt }
            value.isStale = value.isStale || systemIsStale
            return value
        }

    }

    var sessionID: String
    var sessionTitle: String
    var streamID: String?
    var startedAt: Date
    /// Set when a bot owns this activity: the tap target and the avatar. Nil for a
    /// webui session, and for an activity persisted by a build older than #489.
    var bot: AgentRunActivityBot?
    /// The configured server a webui run belongs to, so its relay registration finds
    /// that server's push pairing (#566). Nil for a bot, whose destination names the
    /// server, and for an activity persisted by an older build.
    var server: URL?

    init(sessionID: String, sessionTitle: String, streamID: String? = nil, startedAt: Date,
         bot: AgentRunActivityBot? = nil, server: URL? = nil) {
        self.sessionID = sessionID
        self.sessionTitle = AgentRunActivitySanitizer.sessionTitle(sessionTitle)
        self.streamID = AgentLiveActivityReusePolicy.normalizedStreamID(streamID)
        self.startedAt = startedAt
        self.bot = bot
        self.server = server
    }
}

/// The bot behind a Live Activity (#489). `key` stands in for the session id, so an
/// activity is only ever reused by the same bot on the same Bot connection: equal
/// Profile names on two connections get different keys. The widget sees only this
/// value; the typed `BotDestination` it was built from stays in the main app.
struct AgentRunActivityBot: Codable, Hashable {
    /// `bot:<connection UUID>:<Profile name>`.
    let key: String
    /// The `hermes-agent://bot?...` route a tap opens.
    let destinationURL: URL
    /// File name of the rendered avatar in `AgentRunActivityAvatarFile.directory`,
    /// or nil when none could be written; the widget then keeps the status dot.
    var avatarFile: String?
    /// Stored agent session ID (`session_key`, the resolved compression tip) used
    /// by plugin hooks and the relay. Never the gateway runtime ID or chat root.
    var pushSessionID: String? = nil

    /// One activity per bot turn: a reconnect inside the turn reuses it, the next turn does not.
    func streamID(turn: String) -> String { "\(key)#\(turn)" }
}

/// Where the app leaves a bot's rendered avatar for the widget: one small PNG in the
/// shared app group, since a Live Activity cannot carry image data in its state.
enum AgentRunActivityAvatarFile {
    static var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HermesAppGroupIdentifier") as? String,
              !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("LiveActivityAvatars", isDirectory: true)
    }

    static func url(named name: String?) -> URL? {
        // A bare file name only: the attribute is never allowed to walk out of the directory.
        guard let name, !name.isEmpty, !name.contains("/") else { return nil }
        return directory?.appendingPathComponent(name)
    }
}

enum AgentRunActivityStatus: String, Codable, Hashable, CaseIterable {
    case starting
    case thinking
    case usingTool
    case searchingFiles
    case readingFiles
    case runningCommand
    case responding
    case waiting
    case waitingForApproval
    case waitingForClarification
    case complete
    case failed
    case cancelled

    var title: String {
        switch self {
        case .starting:
            String(localized: "Starting")
        case .thinking:
            String(localized: "Thinking")
        case .usingTool:
            String(localized: "Using tool")
        case .searchingFiles:
            String(localized: "Searching files")
        case .readingFiles:
            String(localized: "Reading files")
        case .runningCommand:
            String(localized: "Running command")
        case .responding:
            String(localized: "Responding")
        case .waiting:
            String(localized: "Waiting for you")
        case .waitingForApproval:
            String(localized: "Waiting for approval")
        case .waitingForClarification:
            String(localized: "Needs clarification")
        case .complete:
            String(localized: "Complete")
        case .failed:
            String(localized: "Failed")
        case .cancelled:
            String(localized: "Cancelled")
        }
    }

    var compactTitle: String {
        switch self {
        case .starting:
            String(localized: "Start")
        case .thinking:
            String(localized: "Think")
        case .usingTool:
            String(localized: "Tool")
        case .searchingFiles:
            String(localized: "Search")
        case .readingFiles:
            String(localized: "Files")
        case .runningCommand:
            String(localized: "Cmd")
        case .responding:
            String(localized: "Reply")
        case .waiting:
            "…"
        case .waitingForApproval:
            String(localized: "Approve")
        case .waitingForClarification:
            String(localized: "Clarify")
        case .complete:
            String(localized: "Done")
        case .failed:
            String(localized: "Fail")
        case .cancelled:
            String(localized: "Stop")
        }
    }
}

enum AgentRunActivityToolKind: Equatable {
    case generic(String)
    case search
    case files
    case command
}

enum AgentRunActivitySanitizer {
    static let maximumSessionTitleCharacters = 42
    static let maximumActivityCharacters = 64
    static let maximumExcerptCharacters = 140
    static let maximumToolLabelCharacters = 28
    static let maximumChips = 3
    static let maximumChipCharacters = 24

    static func chips(_ rawValues: [String]) -> [String] {
        rawValues.map { trimmed(normalizedSingleLine($0), limit: maximumChipCharacters) }
            .filter { !$0.isEmpty }
            .prefix(maximumChips).map { $0 }
    }

    static func sessionTitle(_ rawValue: String) -> String {
        let normalized = normalizedSingleLine(rawValue)
        return trimmed(normalized.isEmpty ? String(localized: "Hermes session") : normalized, limit: maximumSessionTitleCharacters)
    }

    static func activityLine(_ rawValue: String) -> String {
        trimmed(normalizedSingleLine(rawValue), limit: maximumActivityCharacters)
    }

    static func responseExcerpt(_ rawValue: String) -> String {
        let normalized = normalizedSingleLine(rawValue)
        return trimmed(normalized, limit: maximumExcerptCharacters)
    }

    static func toolKind(name: String?) -> AgentRunActivityToolKind {
        let label = toolLabel(name)
        let lowercasedName = (name ?? "").lowercased()
        let lowercasedLabel = label.lowercased()
        let haystack = "\(lowercasedName) \(lowercasedLabel)"

        if haystack.contains("shell")
            || haystack.contains("bash")
            || haystack.contains("terminal")
            || haystack.contains("exec")
            || haystack.contains("command")
            || haystack.contains("xcodebuild")
            || haystack.contains("simctl") {
            return .command
        }

        if haystack.contains("search")
            || haystack.contains("grep")
            || haystack.contains("ripgrep")
            || haystack.contains("rg")
            || haystack.contains("find") {
            return .search
        }

        if haystack.contains("read")
            || haystack.contains("file")
            || haystack.contains("list")
            || haystack.contains("glob")
            || haystack.contains("workspace") {
            return .files
        }

        return .generic(label)
    }

    static func toolLabel(_ rawValue: String?) -> String {
        let fallback = String(localized: "tool")
        guard let rawValue else { return fallback }

        let noPathSeparators = rawValue
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? rawValue
        let words = noPathSeparators
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let normalized = normalizedSingleLine(words)
        return trimmed(normalized.isEmpty ? fallback : normalized, limit: maximumToolLabelCharacters)
    }

    private static func normalizedSingleLine(_ rawValue: String) -> String {
        rawValue
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmed(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        guard limit > 3 else {
            return String(value.prefix(limit))
        }

        let endIndex = value.index(value.startIndex, offsetBy: limit - 3)
        return String(value[..<endIndex]) + "..."
    }
}

enum AgentLiveActivityReusePolicy {
    static func normalizedStreamID(_ streamID: String?) -> String? {
        guard let streamID else { return nil }

        let normalized = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func canReuseActivity(
        existingSessionID: String,
        existingStreamID: String?,
        requestedSessionID: String,
        requestedStreamID: String?
    ) -> Bool {
        existingSessionID == requestedSessionID
            && normalizedStreamID(existingStreamID) == normalizedStreamID(requestedStreamID)
    }
}

enum AgentRunActivityStateReducer {
    static func updatingSessionTitle(
        _ title: String,
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        AgentRunActivityAttributes.ContentState(
            sessionID: state.sessionID,
            sessionTitle: title,
            status: state.status,
            currentActivity: state.currentActivity,
            responseExcerpt: state.responseExcerpt,
            startedAt: state.startedAt,
            updatedAt: now,
            isStale: state.isStale,
            isFinal: state.isFinal,
            errorSummary: state.errorSummary
        )
    }

    static func initialState(
        sessionID: String,
        sessionTitle: String,
        startedAt: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        AgentRunActivityAttributes.ContentState(
            sessionID: sessionID,
            sessionTitle: sessionTitle,
            status: .starting,
            currentActivity: String(localized: "Starting response"),
            startedAt: startedAt,
            updatedAt: startedAt
        )
    }

    static func settingInterimAssistant(
        _ text: String,
        on state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        let excerpt = AgentRunActivitySanitizer.responseExcerpt(text)
        guard !excerpt.isEmpty else { return state }
        return AgentRunActivityAttributes.ContentState(
            sessionID: state.sessionID,
            sessionTitle: state.sessionTitle,
            status: .responding,
            currentActivity: String(localized: "Writing response"),
            responseExcerpt: excerpt,
            startedAt: state.startedAt,
            updatedAt: now
        )
    }

    static func clearingResponseExcerpt(
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        AgentRunActivityAttributes.ContentState(
            sessionID: state.sessionID,
            sessionTitle: state.sessionTitle,
            status: state.status,
            currentActivity: state.currentActivity,
            responseExcerpt: "",
            startedAt: state.startedAt,
            updatedAt: now,
            isStale: state.isStale,
            isFinal: state.isFinal,
            errorSummary: state.errorSummary
        )
    }

    static func reasoning(
        _ text: String,
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        let activity = String(localized: "Thinking")
        return statusState(.thinking, activity: activity, state: state, now: now)
    }

    static func toolStarted(
        name: String?,
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        switch AgentRunActivitySanitizer.toolKind(name: name) {
        case .command:
            return statusState(.runningCommand, activity: String(localized: "Running command"), state: state, now: now)
        case .search:
            return statusState(.searchingFiles, activity: String(localized: "Searching files"), state: state, now: now)
        case .files:
            return statusState(.readingFiles, activity: String(localized: "Reading files"), state: state, now: now)
        case .generic(let label):
            return statusState(.usingTool, activity: String(localized: "Using \(label)"), state: state, now: now)
        }
    }

    static func toolCompleted(
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        statusState(.responding, activity: String(localized: "Processing result"), state: state, now: now)
    }

    static func responding(
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        statusState(.responding, activity: String(localized: "Writing response"), state: state, now: now)
    }

    static func waitingForApproval(
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        statusState(.waitingForApproval, activity: String(localized: "Waiting for approval"), state: state, now: now)
    }

    static func waitingForClarification(
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        statusState(.waitingForClarification, activity: String(localized: "Needs clarification"), state: state, now: now)
    }

    static func stale(
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        AgentRunActivityAttributes.ContentState(
            sessionID: state.sessionID,
            sessionTitle: state.sessionTitle,
            status: state.status,
            currentActivity: state.currentActivity.isEmpty ? String(localized: "Latest status shown") : state.currentActivity,
            responseExcerpt: state.responseExcerpt,
            startedAt: state.startedAt,
            updatedAt: now,
            isStale: true,
            isFinal: state.isFinal,
            errorSummary: state.errorSummary
        )
    }

    static func final(
        status: AgentRunActivityStatus,
        activity: String,
        state: AgentRunActivityAttributes.ContentState,
        errorSummary: String? = nil,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        AgentRunActivityAttributes.ContentState(
            sessionID: state.sessionID,
            sessionTitle: state.sessionTitle,
            status: status,
            currentActivity: activity,
            responseExcerpt: state.responseExcerpt,
            startedAt: state.startedAt,
            updatedAt: now,
            isStale: false,
            isFinal: true,
            errorSummary: errorSummary
        )
    }

    private static func statusState(
        _ status: AgentRunActivityStatus,
        activity: String,
        state: AgentRunActivityAttributes.ContentState,
        now: Date
    ) -> AgentRunActivityAttributes.ContentState {
        AgentRunActivityAttributes.ContentState(
            sessionID: state.sessionID,
            sessionTitle: state.sessionTitle,
            status: status,
            currentActivity: activity,
            responseExcerpt: state.responseExcerpt,
            startedAt: state.startedAt,
            updatedAt: now
        )
    }
}
