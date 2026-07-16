import SwiftUI

/// ChatGPT-style session row: title + preview snippet + active-stream dot.
/// No date, count, workspace, or badges — just the essentials with larger
/// Gemini-style typography.
struct SessionRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let session: SessionSummary
    var isViewingCachedData = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isActiveStreaming {
                ActiveSessionStreamingIndicator()
                    .padding(.top, 6)
            }

            titleText
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    static func displayTitle(for session: SessionSummary) -> String {
        let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else {
            return String(localized: "Untitled Session")
        }
        return title
    }

    static func isActiveStreaming(_ session: SessionSummary) -> Bool {
        session.isStreaming == true || nonEmpty(session.activeStreamId) != nil
    }

    private var displayTitle: String {
        Self.displayTitle(for: session)
    }

    private var isActiveStreaming: Bool {
        Self.isActiveStreaming(session)
    }

    private var titleText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(displayTitle)
                .font(AppFont.headline(weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .truncationMode(.tail)

            if session.pinned == true {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
    }

    private var accessibilitySummary: String {
        var parts = [displayTitle]
        if isActiveStreaming { parts.append(String(localized: "Streaming")) }
        if session.pinned == true { parts.append(String(localized: "Pinned")) }
        if isViewingCachedData { parts.append(String(localized: "Cached")) }
        return parts.joined(separator: ", ")
    }
}

private struct ActiveSessionStreamingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 9, height: 9)
            .scaleEffect(reduceMotion ? 1 : (isExpanded ? 1.4 : 1.0))
            .accessibilityHidden(true)
            .onAppear { updateAnimation() }
            .onChange(of: reduceMotion) { updateAnimation() }
            .onDisappear { isExpanded = false }
    }

    private func updateAnimation() {
        guard !reduceMotion else { isExpanded = false; return }
        isExpanded = false
        withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
            isExpanded = true
        }
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// ---------------------------------------------------------------------------
// Settings enums kept for the session list — not display-related anymore but
// still referenced by SessionListView and its filters.
// ---------------------------------------------------------------------------

enum SessionRowDisplaySettings {
    static let showMessageCountKey = "sessionRow.showMessageCount"
    static let showWorkspaceKey = "sessionRow.showWorkspace"
    static let showCronSessionsKey = "sessionRow.showCronSessions"
    static let showSubagentSessionsKey = "sessionRow.showSubagentSessions"
    static let defaultShowsSubagentSessions = false
    static let showCliSessionsKey = "sessionRow.showCliSessions"
    static let showClaudeCodeSessionsKey = "sessionRow.showClaudeCodeSessions"

    static func showCliSessionsKey(for server: URL) -> String {
        "\(showCliSessionsKey)|\(server.absoluteString)"
    }

    static func showClaudeCodeSessionsKey(for server: URL) -> String {
        "\(showClaudeCodeSessionsKey)|\(server.absoluteString)"
    }

    static func showsCliSessions(for server: URL, in defaults: UserDefaults = .standard) -> Bool {
        if let perServer = defaults.object(forKey: showCliSessionsKey(for: server)) as? Bool {
            return perServer
        }
        if let legacy = defaults.object(forKey: showCliSessionsKey) as? Bool {
            return legacy
        }
        return true
    }

    static func showsClaudeCodeSessions(for server: URL, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showClaudeCodeSessionsKey(for: server)) as? Bool ?? true
    }

    static func showsSubagentSessions(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showSubagentSessionsKey) as? Bool ?? defaultShowsSubagentSessions
    }
}

enum SessionSidebarDisclosureSettings {
    static let profilesAreExpandedKey = "sessionSidebar.profilesAreExpanded"
    static let projectsAreExpandedKey = "sessionSidebar.projectsAreExpanded"
    static let scheduledSessionsAreExpandedKey = "sessionSidebar.scheduledSessionsAreExpanded"
    static let defaultProfilesAreExpanded = false
    static let defaultProjectsAreExpanded = false
    static let defaultScheduledSessionsAreExpanded = false

    static func profilesAreExpanded(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: profilesAreExpandedKey) as? Bool ?? defaultProfilesAreExpanded
    }
    static func projectsAreExpanded(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: projectsAreExpandedKey) as? Bool ?? defaultProjectsAreExpanded
    }
    static func scheduledSessionsAreExpanded(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: scheduledSessionsAreExpandedKey) as? Bool ?? defaultScheduledSessionsAreExpanded
    }
}

enum SessionIdentitySettings {
    static let displayNameKey = "sessionIdentity.displayName"
    static let initialsKey = "sessionIdentity.initials"

    static func normalizedInitials(_ rawValue: String) -> String {
        rawValue.filter { $0.isLetter || $0.isNumber }.prefix(3).map { String($0).uppercased() }.joined()
    }

    static func displayInitials(displayName: String, storedInitials: String, fallbackFullName: String) -> String {
        let normalizedStoredInitials = normalizedInitials(storedInitials)
        if !normalizedStoredInitials.isEmpty { return normalizedStoredInitials }
        let displayNameInitials = initials(from: displayName)
        if !displayNameInitials.isEmpty { return displayNameInitials }
        let fallbackInitials = initials(from: fallbackFullName)
        return fallbackInitials.isEmpty ? "UZ" : fallbackInitials
    }

    private static func initials(from rawName: String) -> String {
        rawName.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .compactMap(\.first)
            .prefix(2)
            .map { String($0).uppercased() }
            .joined()
    }
}
