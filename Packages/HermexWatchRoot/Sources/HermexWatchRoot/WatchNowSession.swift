import Foundation
import WatchShared

/// Picks the session the wrist should operate on, and the complication activity.
public enum WatchNowSession {
    public static func isRunning(_ phase: WatchRunPhase?) -> Bool {
        switch phase {
        case .starting, .thinking, .tool, .searching, .files, .command, .responding:
            return true
        case .attention, .completed, .failed, .stopped, .unknown, nil:
            return false
        }
    }

    public static func needsAttention(_ session: WatchSessionSummary) -> Bool {
        session.attention || session.runState == .attention
    }

    public static func preferred(from sessions: [WatchSessionSummary]) -> WatchSessionSummary? {
        let active = sessions.filter { !$0.isArchived }
        if let running = active.first(where: { isRunning($0.runState) }) {
            return running
        }
        if let attention = active.first(where: needsAttention) {
            return attention
        }
        if let pinned = active.first(where: \.isPinned) {
            return pinned
        }
        return active.max { lhs, rhs in
            (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
        } ?? sessions.first
    }

    public static func widgetActivity(from sessions: [WatchSessionSummary]) -> RedactedWidgetSnapshot.Activity {
        if sessions.contains(where: { isRunning($0.runState) }) {
            return .running
        }
        if sessions.contains(where: needsAttention) {
            return .needsAttention
        }
        if sessions.isEmpty {
            return .unknown
        }
        return .idle
    }
}

public enum WatchTranscriptPreview {
    /// Wrist-length upper bound for reading a reply aloud (about a minute of
    /// speech); the rest is on iPhone.
    public static let maximumSpokenCharacters = 1_200

    /// The latest assistant turn as speakable words: every assistant text block
    /// after the last user message, Markdown and links reduced to their words.
    /// Code and tool rows are skipped rather than spelled out. `nil` when the
    /// latest turn has nothing to read, so Read aloud can be disabled instead of
    /// speaking an empty or unrelated utterance.
    public static func lastAssistantReply(
        in blocks: [WatchTranscriptBlock],
        maxCharacters: Int = maximumSpokenCharacters
    ) -> String? {
        var parts: [String] = []
        for block in blocks.reversed() {
            guard case .text(_, let role, let text) = block else { continue }
            if role == .user { break }
            guard role == .assistant else { continue }
            let words = WatchTranscriptProjection.plainText(text)
                .replacingOccurrences(of: "…", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { parts.insert(words, at: 0) }
        }
        let spoken = parts.joined(separator: "\n")
        guard !spoken.isEmpty else { return nil }
        guard spoken.count > maxCharacters else { return spoken }
        // Stop on a sentence or word boundary so speech never ends mid-word.
        let clipped = String(spoken.prefix(maxCharacters))
        if let stop = clipped.lastIndex(where: { ".!?\n".contains($0) }), clipped.distance(from: clipped.startIndex, to: stop) > maxCharacters / 2 {
            return String(clipped[...stop])
        }
        if let space = clipped.lastIndex(of: " ") {
            return String(clipped[..<space])
        }
        return clipped
    }

    public static func lastAssistantText(in blocks: [WatchTranscriptBlock], maxCharacters: Int = 160) -> String? {
        for block in blocks.reversed() {
            if case .text(_, let role, let text) = block, role == .assistant {
                // Glance lines and the spoken reply want the words, not the
                // Markdown the transcript renderer styles.
                let trimmed = WatchTranscriptProjection.plainText(text)
                guard !trimmed.isEmpty else { continue }
                if trimmed.count <= maxCharacters { return trimmed }
                return String(trimmed.prefix(maxCharacters - 1)) + "…"
            }
        }
        return nil
    }
}
