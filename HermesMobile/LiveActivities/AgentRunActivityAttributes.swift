import ActivityKit
import Foundation

struct AgentRunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var sessionID: String
        var sessionTitle: String
        var status: AgentRunActivityStatus
        var currentActivity: String
        var responseExcerpt: String
        var startedAt: Date
        var updatedAt: Date
        var isStale: Bool
        var isFinal: Bool
        var errorSummary: String?

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
            self.status = status
            self.currentActivity = AgentRunActivitySanitizer.activityLine(currentActivity)
            self.responseExcerpt = AgentRunActivitySanitizer.responseExcerpt(responseExcerpt)
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.isStale = isStale
            self.isFinal = isFinal
            self.errorSummary = errorSummary.map(AgentRunActivitySanitizer.activityLine)
        }
    }

    var sessionID: String
    var sessionTitle: String
    var streamID: String?
    var startedAt: Date

    init(sessionID: String, sessionTitle: String, streamID: String? = nil, startedAt: Date) {
        self.sessionID = sessionID
        self.sessionTitle = AgentRunActivitySanitizer.sessionTitle(sessionTitle)
        self.streamID = AgentLiveActivityReusePolicy.normalizedStreamID(streamID)
        self.startedAt = startedAt
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

enum AgentRunElapsedTimeFormatter {
    static func label(startedAt: Date, updatedAt: Date) -> String {
        let elapsedSeconds = max(0, Int(updatedAt.timeIntervalSince(startedAt).rounded(.down)))
        let hours = elapsedSeconds / 3_600
        let minutes = (elapsedSeconds % 3_600) / 60
        let seconds = elapsedSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
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

    static func appendingToken(
        _ text: String,
        to state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        guard !text.isEmpty else { return state }
        return AgentRunActivityAttributes.ContentState(
            sessionID: state.sessionID,
            sessionTitle: state.sessionTitle,
            status: .responding,
            currentActivity: String(localized: "Writing response"),
            responseExcerpt: state.responseExcerpt + text,
            startedAt: state.startedAt,
            updatedAt: now
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

    /// Capsule verb vocabulary for tool activity lines, mirroring
    /// `ThinkingOrbState.forTool` in Features/Chat/ThinkingOrbView.swift (the
    /// source of truth for the in-app activity capsule). Duplicated here rather
    /// than referenced because this file also compiles into the widget target,
    /// which does not include ThinkingOrbView.swift.
    static func capsuleVerb(forToolNamed name: String?) -> String {
        let name = name?.lowercased() ?? ""

        let writing = ["write", "edit", "create", "apply_patch", "patch", "insert", "replace"]
        if writing.contains(where: { name.contains($0) }) {
            return String(localized: "Writing")
        }

        let reading = ["search", "read", "grep", "list", "web", "find", "glob", "fetch", "view"]
        if reading.contains(where: { name.contains($0) }) {
            return String(localized: "Reading")
        }

        let connecting = ["network", "server", "session", "connect", "http", "request", "api"]
        if connecting.contains(where: { name.contains($0) }) {
            return String(localized: "Connecting")
        }

        return String(localized: "Working")
    }

    /// "Verb · toolname" where a tool name exists (e.g. "Reading · read_file"),
    /// plain verb otherwise. The ContentState initializer's sanitizer enforces
    /// the single-line/length limits, so the raw name is safe to pass through.
    private static func capsuleActivityLine(forToolNamed name: String?) -> String {
        let verb = capsuleVerb(forToolNamed: name)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedName.isEmpty else { return verb }
        return "\(verb) · \(trimmedName)"
    }

    static func toolStarted(
        name: String?,
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        // The status (widget glyph/title) keeps the established kind mapping;
        // only the user-visible activity line adopts the capsule verb wording.
        let activity = capsuleActivityLine(forToolNamed: name)
        switch AgentRunActivitySanitizer.toolKind(name: name) {
        case .command:
            return statusState(.runningCommand, activity: activity, state: state, now: now)
        case .search:
            return statusState(.searchingFiles, activity: activity, state: state, now: now)
        case .files:
            return statusState(.readingFiles, activity: activity, state: state, now: now)
        case .generic:
            return statusState(.usingTool, activity: activity, state: state, now: now)
        }
    }

    static func toolCompleted(
        state: AgentRunActivityAttributes.ContentState,
        now: Date = Date()
    ) -> AgentRunActivityAttributes.ContentState {
        statusState(.responding, activity: String(localized: "Processing result"), state: state, now: now)
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
