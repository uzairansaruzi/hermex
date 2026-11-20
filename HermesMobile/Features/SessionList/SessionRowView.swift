import SwiftUI

struct SessionRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var pinnedIconSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var verticalPadding: CGFloat = 8

    let session: SessionSummary
    var showsMessageCount = true
    var showsWorkspace = true
    var isViewingCachedData = false
    var isCachedCopyProvisional = false
    var isUnread = false
    var attentionState: SessionRowAttentionState?
    var isAttentionStale = false
    var searchExcerpt: SessionSearchExcerpt?
    var labelsArchived = false
    var profileTag: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUnread && effectiveAttentionState == nil {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .padding(.top, unreadDotTopPadding)
                    .accessibilityHidden(true)
            }

            rowContent
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: rowMinimumHeight, alignment: .center)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    static func displayTitle(for session: SessionSummary) -> String {
        let title = [session.title, session.hermes?.preview]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return title ?? String(localized: "Untitled Session")
    }

    static func isActiveStreaming(_ session: SessionSummary) -> Bool {
        session.isStreaming == true || nonEmpty(session.activeStreamId) != nil
    }

    static func metadataLabel(
        for session: SessionSummary,
        showsMessageCount: Bool,
        showsWorkspace: Bool
    ) -> String? {
        let parts = [
            messageCountLabel(for: session, showsMessageCount: showsMessageCount),
            workspaceLabel(for: session, showsWorkspace: showsWorkspace)
        ].compactMap(\.self)

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    static func effectiveAttentionState(
        for session: SessionSummary,
        attentionState: SessionRowAttentionState?,
        isViewingCachedData: Bool
    ) -> SessionRowAttentionState? {
        if let attentionState {
            return attentionState
        }

        guard !isViewingCachedData else { return nil }

        return SessionRowAttentionState.resolve(
            session: session,
            hasPendingApproval: false,
            hasPendingClarification: false
        )
    }

    static func accessibilityStateLabels(
        for session: SessionSummary,
        isViewingCachedData: Bool,
        isCachedCopyProvisional: Bool = false,
        attentionState: SessionRowAttentionState? = nil,
        isAttentionStale: Bool = false,
        isUnread: Bool = false,
        labelsArchived: Bool = false
    ) -> [String] {
        var labels: [String] = []

        if let state = effectiveAttentionState(
            for: session,
            attentionState: attentionState,
            isViewingCachedData: isViewingCachedData
        ) {
            labels.append(isAttentionStale && attentionState != nil
                ? String(localized: "Last known: \(state.accessibilityLabel)")
                : state.accessibilityLabel)
        } else if isUnread {
            labels.append(String(localized: "Unread"))
        }

        if session.pinned == true {
            labels.append(String(localized: "Pinned"))
        }

        if isViewingCachedData && !isCachedCopyProvisional {
            labels.append(String(localized: "Cached"))
        }

        if let sourceLabel = session.sourceDisplayLabel {
            labels.append(sourceLabel)
        }

        if session.isSessionReadOnly {
            labels.append(String(localized: "Read-only"))
        }

        if labelsArchived && session.archived == true {
            labels.append(String(localized: "Archived"))
        }

        return labels
    }

    private var displayTitle: String {
        Self.displayTitle(for: session)
    }

    private static func messageCountLabel(for session: SessionSummary, showsMessageCount: Bool) -> String? {
        guard showsMessageCount else { return nil }
        guard let count = session.messageCount, count >= 0 else { return nil }
        return String(localized: "\(count) messages")
    }

    private static func workspaceLabel(for session: SessionSummary, showsWorkspace: Bool) -> String? {
        guard showsWorkspace else { return nil }
        guard let workspace = session.workspace?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspace.isEmpty
        else {
            return nil
        }

        let lastPathComponent = (workspace as NSString).lastPathComponent
        return lastPathComponent.isEmpty ? workspace : lastPathComponent
    }

    private var metadataLabel: String? {
        Self.metadataLabel(
            for: session,
            showsMessageCount: showsMessageCount,
            showsWorkspace: showsWorkspace
        )
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: rowContentSpacing) {
            titleArea

            if let searchExcerpt {
                excerptText(searchExcerpt)
            }

            if showsSupplementalContent {
                supplementalArea
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var titleArea: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                titleAndPin

                trailingStatusSlot
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleAndPin

                if showsTrailingStatus {
                    Spacer(minLength: 8)
                }

                trailingStatusSlot
            }
        }
    }

    @ViewBuilder
    private var trailingStatusSlot: some View {
        if let effectiveAttentionState {
            attentionStateText(effectiveAttentionState)
        } else if Self.lastActivityDate(for: session) != nil {
            TimelineView(.everyMinute) { _ in
                relativeDateText(Self.relativeDateLabel(for: session, now: .now) ?? "")
            }
        }
    }

    private var showsTrailingStatus: Bool {
        effectiveAttentionState != nil || Self.lastActivityDate(for: session) != nil
    }

    private var effectiveAttentionState: SessionRowAttentionState? {
        Self.effectiveAttentionState(
            for: session,
            attentionState: attentionState,
            isViewingCachedData: isViewingCachedData
        )
    }

    private func attentionStateText(_ state: SessionRowAttentionState) -> some View {
        Text(state.title)
            .font(AppFont.caption(weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(isAttentionStale && attentionState != nil ? AnyShapeStyle(.appSecondary) : AnyShapeStyle(state.tint))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    private var titleAndPin: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(displayTitle)
                .font(AppFont.headline(weight: .semibold))
                .foregroundStyle(.appPrimary)
                .lineLimit(titleLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)

            if session.pinned == true {
                Image(systemName: "pin.fill")
                    .font(.system(size: pinnedIconSize, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
    }

    private func relativeDateText(_ text: String) -> some View {
        Text(text)
            .font(AppFont.caption())
            .foregroundStyle(.appSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    private func excerptText(_ excerpt: SessionSearchExcerpt) -> some View {
        Text(excerpt.highlighted)
            .font(AppFont.caption())
            .foregroundStyle(.appSecondary)
            .lineLimit(excerptLineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var supplementalArea: some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    if let profileTag {
                        SessionProfileTag(profile: profileTag)
                    }

                    if !visibleStateBadges.isEmpty {
                        stateBadgesRow
                    }

                    if let metadataLabel {
                        metadataText(metadataLabel)
                    }
                }

                Spacer(minLength: 8)

                if let sourceLabel = session.sourceDisplayLabel {
                    SessionSourceBadge(label: sourceLabel)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let profileTag {
                    SessionProfileTag(profile: profileTag)
                }

                if !visibleStateBadges.isEmpty {
                    stateBadgesRow
                }

                if let metadataLabel {
                    metadataText(metadataLabel)
                }

                Spacer(minLength: 8)

                if let sourceLabel = session.sourceDisplayLabel {
                    SessionSourceBadge(label: sourceLabel)
                }
            }
        }
    }

    private var stateBadgesRow: some View {
        HStack(spacing: 5) {
            ForEach(visibleStateBadges) { badge in
                SessionRowStateBadge(badge: badge)
            }
        }
    }

    private func metadataText(_ text: String) -> some View {
        Text(text)
            .font(AppFont.caption())
            .foregroundStyle(.appSecondary)
            .lineLimit(metadataLineLimit)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var visibleStateBadges: [SessionRowStateBadgeKind] {
        var badges: [SessionRowStateBadgeKind] = []

        if isViewingCachedData && !isCachedCopyProvisional {
            badges.append(.cached)
        }

        if session.isSessionReadOnly {
            badges.append(.readOnly)
        }

        if labelsArchived && session.archived == true {
            badges.append(.archived)
        }

        return badges
    }

    private var showsStateBadges: Bool {
        session.sourceDisplayLabel != nil || !visibleStateBadges.isEmpty
    }

    private var showsSupplementalContent: Bool {
        metadataLabel != nil || showsStateBadges || profileTag != nil
    }

    private var rowContentSpacing: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 6 : 4
    }

    private var rowMinimumHeight: CGFloat {
        let base: CGFloat = showsSupplementalContent ? 54 : 46
        return searchExcerpt == nil ? base : base + 16
    }

    private var titleLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 2
    }

    private var metadataLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 1
    }

    private var excerptLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 1
    }

    private var unreadDotTopPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 8 : 7
    }

    static func relativeDateLabel(for session: SessionSummary, now: Date) -> String? {
        guard let lastActivity = lastActivityDate(for: session) else { return nil }
        return SessionRelativeDateFormatter.shared.localizedString(for: lastActivity, relativeTo: now)
    }

    private static func lastActivityDate(for session: SessionSummary) -> Date? {
        let timestamp = session.lastMessageAt ?? session.updatedAt ?? session.createdAt
        guard let timestamp, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private var accessibilitySummary: String {
        var parts = [displayTitle]

        if let searchExcerpt {
            parts.append(String(localized: "Matched: \(searchExcerpt.text)"))
        }

        if let profileTag {
            parts.append(String(localized: "Profile: \(profileTag)"))
        }

        parts.append(contentsOf: Self.accessibilityStateLabels(
            for: session,
            isViewingCachedData: isViewingCachedData,
            isCachedCopyProvisional: isCachedCopyProvisional,
            attentionState: attentionState,
            isAttentionStale: isAttentionStale,
            isUnread: isUnread,
            labelsArchived: labelsArchived
        ))

        if let metadataLabel {
            parts.append(metadataLabel)
        }

        if let relativeDate = Self.relativeDateLabel(for: session, now: Date()) {
            parts.append(relativeDate)
        }

        return parts.joined(separator: ", ")
    }
}

enum SessionRowAttentionState: String, Equatable {
    case approval
    case input
    case working

    static func resolve(
        session: SessionSummary,
        hasPendingApproval: Bool,
        hasPendingClarification: Bool
    ) -> SessionRowAttentionState? {
        if hasPendingApproval {
            return .approval
        }

        if hasPendingClarification {
            return .input
        }

        return SessionRowView.isActiveStreaming(session) ? .working : nil
    }

    var title: String {
        switch self {
        case .approval:
            return String(localized: "Approval")
        case .input:
            return String(localized: "Input")
        case .working:
            return String(localized: "Working")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .approval:
            return String(localized: "Waiting for approval")
        case .input:
            return String(localized: "Needs input")
        case .working:
            return String(localized: "Working")
        }
    }

    var tint: Color {
        switch self {
        case .approval:
            return Color("AttentionApproval")
        case .input:
            return Color("AttentionInput")
        case .working:
            return Color("AttentionWorking")
        }
    }
}

private enum SessionRowStateBadgeKind: String, Identifiable {
    case cached
    case readOnly
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cached:
            return String(localized: "Cached")
        case .readOnly:
            return String(localized: "Read-only")
        case .archived:
            return String(localized: "Archived")
        }
    }

    var tint: Color {
        switch self {
        case .cached:
            return .orange
        case .readOnly, .archived:
            return .gray
        }
    }
}

private struct SessionSourceBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(AppFont.caption2(weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .accessibilityHidden(true)
    }
}

private struct SessionProfileTag: View {
    let profile: String

    var body: some View {
        Text(verbatim: profile)
            .font(AppFont.caption2(weight: .semibold))
            .foregroundStyle(.appSecondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(.appTextSecondary).opacity(0.12), in: Capsule())
            .accessibilityHidden(true)
    }
}

private struct SessionRowStateBadge: View {
    let badge: SessionRowStateBadgeKind

    var body: some View {
        Text(badge.title)
            .font(AppFont.caption2(weight: .semibold))
            .foregroundStyle(badge.tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(badge.tint.opacity(0.12), in: Capsule())
            .accessibilityHidden(true)
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

enum SessionRelativeDateFormatter {
    static let shared: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

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

    static func showsClaudeCodeSessions(
        for server: URL,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: showClaudeCodeSessionsKey(for: server)) as? Bool ?? true
    }
}

enum SessionSidebarDisclosureSettings {
    static let profilesAreExpandedKey = "sessionSidebar.profilesAreExpanded"
    static let projectsAreExpandedKey = "sessionSidebar.projectsAreExpanded"
    static let scheduledSessionsAreExpandedKey = "sessionSidebar.scheduledSessionsAreExpanded"
    static let defaultProfilesAreExpanded = false
    static let defaultProjectsAreExpanded = false
    static let defaultScheduledSessionsAreExpanded = false
}

enum SessionIdentitySettings {
    static let displayNameKey = "sessionIdentity.displayName"
    static let initialsKey = "sessionIdentity.initials"

    static func normalizedInitials(_ rawValue: String) -> String {
        rawValue
            .filter { $0.isLetter || $0.isNumber }
            .prefix(3)
            .map { String($0).uppercased() }
            .joined()
    }

    static func displayInitials(
        displayName: String,
        storedInitials: String,
        fallbackFullName: String
    ) -> String {
        let normalizedStoredInitials = normalizedInitials(storedInitials)
        if !normalizedStoredInitials.isEmpty {
            return normalizedStoredInitials
        }

        let displayNameInitials = initials(from: displayName)
        if !displayNameInitials.isEmpty {
            return displayNameInitials
        }

        let fallbackInitials = initials(from: fallbackFullName)
        return fallbackInitials.isEmpty ? "UZ" : fallbackInitials
    }

    private static func initials(from rawName: String) -> String {
        rawName
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .compactMap(\.first)
            .prefix(2)
            .map { String($0).uppercased() }
            .joined()
    }
}
