import SwiftUI

struct SessionRowView: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var pinnedIconSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var sourceIconSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var verticalPadding: CGFloat = 8

    let session: SessionSummary
    var showsMessageCount = true
    var showsWorkspace = true
    var isViewingCachedData = false
    var nestingLevel = 0

    private var isNestedChild: Bool { nestingLevel > 0 || session.isChildSession || session.isSubagentSession }

    var body: some View {
        HStack(alignment: .top, spacing: isNestedChild ? 8 : 10) {
            if isNestedChild {
                childBranchGlyph
                    .padding(.top, streamingIndicatorTopPadding - 2)
            }

            ActiveSessionStreamingIndicator(isActive: Self.isActiveStreaming(session))
                .padding(.top, streamingIndicatorTopPadding)

            rowContent
        }
        .padding(.leading, isNestedChild ? 30 : 14)
        .padding(.trailing, 14)
        .padding(.vertical, rowVerticalPadding)
        .frame(minHeight: rowMinimumHeight, alignment: .center)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(rowDivider)
                .frame(height: colorSchemeContrast == .increased ? 1 : 0.65)
                .padding(.leading, Self.isActiveStreaming(session) ? 30 : 0)
                .allowsHitTesting(false)
        }
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

    static func isScheduledSession(_ session: SessionSummary) -> Bool {
        session.isCronSession
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

    static func accessibilityStateLabels(
        for session: SessionSummary,
        isViewingCachedData: Bool
    ) -> [String] {
        var labels: [String] = []

        if isActiveStreaming(session) {
            labels.append(String(localized: "Streaming"))
        }

        if session.pinned == true {
            labels.append(String(localized: "Pinned"))
        }

        if isScheduledSession(session) {
            labels.append(String(localized: "Scheduled"))
        }

        if session.isSubagentSession {
            labels.append(String(localized: "Sub-agent"))
        }

        if session.isReadOnlySession {
            labels.append(String(localized: "Read-only"))
        }

        if isViewingCachedData {
            labels.append(String(localized: "Cached"))
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

                if let relativeDate {
                    relativeDateText(relativeDate)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleAndPin

                if let relativeDate {
                    Spacer(minLength: 8)

                    relativeDateText(relativeDate)
                }
            }
        }
    }

    private var titleAndPin: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(displayTitle)
                .font(isNestedChild ? AppFont.subheadline(weight: .semibold) : AppFont.headline(weight: .semibold))
                .foregroundStyle(isNestedChild ? ZoraBrand.secondaryForeground : ZoraBrand.foreground)
                .lineLimit(titleLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)

            if session.pinned == true {
                Image(systemName: "pin.fill")
                    .font(.system(size: pinnedIconSize, weight: .semibold))
                    .foregroundStyle(ZoraBrand.selectionAccent)
                    .accessibilityHidden(true)
            }
        }
    }

    private func relativeDateText(_ text: String) -> some View {
        Text(text)
            .font(AppFont.caption())
            .foregroundStyle(ZoraBrand.tertiaryForeground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var supplementalArea: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                if !visibleStateBadges.isEmpty {
                    stateBadgesRow
                }

                if let metadataLabel {
                    metadataText(metadataLabel)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if !visibleStateBadges.isEmpty {
                    stateBadgesRow
                }

                if let metadataLabel {
                    metadataText(metadataLabel)
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
            .foregroundStyle(ZoraBrand.secondaryForeground)
            .lineLimit(metadataLineLimit)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func stateBadgeKinds(
        for session: SessionSummary,
        isViewingCachedData: Bool
    ) -> [SessionRowStateBadgeKind] {
        var badges: [SessionRowStateBadgeKind] = []

        if isScheduledSession(session) {
            badges.append(.scheduled)
        }

        if isViewingCachedData {
            badges.append(.cached)
        }

        return badges
    }

    private var visibleStateBadges: [SessionRowStateBadgeKind] {
        var badges = Self.stateBadgeKinds(for: session, isViewingCachedData: isViewingCachedData)
        if isNestedChild, !badges.contains(.subagent) {
            badges.insert(.subagent, at: 0)
        }
        if session.isReadOnlySession, !badges.contains(.readOnly) {
            badges.append(.readOnly)
        }
        return badges
    }

    private var showsSupplementalContent: Bool {
        metadataLabel != nil || !visibleStateBadges.isEmpty
    }

    private var rowContentSpacing: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 6 : 4
    }

    private var rowVerticalPadding: CGFloat {
        let base = verticalPadding + (dynamicTypeSize.isAccessibilitySize ? 3 : 2)
        return isNestedChild ? max(5, base - 3) : base
    }

    private var rowMinimumHeight: CGFloat {
        if isNestedChild {
            return showsSupplementalContent ? 52 : 44
        }
        return showsSupplementalContent ? 62 : 52
    }

    private var titleLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 2
    }

    private var metadataLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 1
    }

    private var streamingIndicatorTopPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 10 : 9
    }

    private var rowDivider: Color {
        if colorSchemeContrast == .increased {
            return ZoraBrand.foreground.opacity(0.30)
        }

        if isNestedChild {
            return ZoraBrand.listDivider.opacity(0.62)
        }

        return Self.isActiveStreaming(session) ? ZoraBrand.listDividerStrong : ZoraBrand.listDivider
    }

    private var childBranchGlyph: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(ZoraBrand.tertiaryForeground.opacity(0.38))
                .frame(width: 1, height: 12)

            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ZoraBrand.tertiaryForeground.opacity(0.78))
        }
        .frame(width: 14)
        .accessibilityHidden(true)
    }

    private var relativeDate: String? {
        let timestamp = session.lastMessageAt ?? session.updatedAt ?? session.createdAt
        guard let timestamp, timestamp > 0 else { return nil }

        return SessionRelativeDateFormatter.shared.localizedString(
            for: Date(timeIntervalSince1970: timestamp),
            relativeTo: Date()
        )
    }

    private var accessibilitySummary: String {
        var parts = [displayTitle]

        parts.append(contentsOf: Self.accessibilityStateLabels(for: session, isViewingCachedData: isViewingCachedData))

        if let metadataLabel {
            parts.append(metadataLabel)
        }

        if let relativeDate {
            parts.append(relativeDate)
        }

        return parts.joined(separator: ", ")
    }
}

enum SessionRowStateBadgeKind: String, Identifiable {
    case scheduled
    case subagent
    case readOnly
    case cached

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scheduled:
            return String(localized: "Scheduled")
        case .subagent:
            return String(localized: "Sub-agent")
        case .readOnly:
            return String(localized: "View-only")
        case .cached:
            return String(localized: "Cached")
        }
    }

    var tint: Color {
        switch self {
        case .scheduled:
            return ZoraBrand.selectionAccent
        case .subagent:
            return ZoraBrand.tertiaryForeground
        case .readOnly:
            return .blue
        case .cached:
            return .orange
        }
    }
}

private struct SessionRowStateBadge: View {
    let badge: SessionRowStateBadgeKind

    var body: some View {
        HStack(spacing: 4) {
            switch badge {
            case .scheduled:
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 9, weight: .bold))
            case .subagent:
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8, weight: .bold))
            case .readOnly:
                Image(systemName: "lock")
                    .font(.system(size: 8, weight: .bold))
            case .cached:
                Circle()
                    .fill(badge.tint)
                    .frame(width: 5, height: 5)
            }

            Text(badge.title)
                .font(AppFont.caption2(weight: .bold))
                .tracking(0.2)
        }
        .foregroundStyle(ZoraBrand.foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(badge.tint.opacity(0.22), in: Capsule())
        .overlay {
            Capsule()
                .stroke(badge.tint.opacity(0.34), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}

private struct ActiveSessionStreamingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    let isActive: Bool

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 9, height: 9)
            .scaleEffect(reduceMotion || !isActive ? 1 : (isExpanded ? 1.4 : 1.0))
            .opacity(isActive ? 1 : 0)
            .shadow(color: Color.green.opacity(isActive ? 0.42 : 0), radius: 8)
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)
            .onAppear {
                updateAnimation()
            }
            .onChange(of: isActive) {
                updateAnimation()
            }
            .onChange(of: reduceMotion) {
                updateAnimation()
            }
            .onDisappear {
                isExpanded = false
            }
    }

    private func updateAnimation() {
        guard isActive, !reduceMotion else {
            isExpanded = false
            return
        }

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

private enum SessionRelativeDateFormatter {
    static let shared: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

enum SessionRowDisplaySettings {
    static let showMessageCountKey = "sessionRow.showMessageCount"
    static let showWorkspaceKey = "sessionRow.showWorkspace"
    // Cron, CLI, and read-only/view-only sessions are controlled independently
    // (#256); all default to shown, and their toggles let users hide each kind
    // separately.
    static let showCronSessionsKey = "sessionRow.showCronSessions"
    static let showCliSessionsKey = "sessionRow.showCliSessions"
    static let showReadOnlySessionsKey = "sessionRow.showReadOnlySessions"
}

enum SessionSidebarDisclosureSettings {
    static let profilesAreExpandedKey = "sessionSidebar.profilesAreExpanded"
    static let projectsAreExpandedKey = "sessionSidebar.projectsAreExpanded"
    static let defaultProfilesAreExpanded = false
    static let defaultProjectsAreExpanded = false

    static func profilesAreExpanded(in defaults: UserDefaults = .standard) -> Bool {
        guard let value = defaults.object(forKey: profilesAreExpandedKey) as? Bool else {
            return defaultProfilesAreExpanded
        }

        return value
    }

    static func projectsAreExpanded(in defaults: UserDefaults = .standard) -> Bool {
        guard let value = defaults.object(forKey: projectsAreExpandedKey) as? Bool else {
            return defaultProjectsAreExpanded
        }

        return value
    }
}

enum SessionAvatarStyle: String, CaseIterable, Identifiable {
    case initials
    case zora
    case orbital

    static let storageKey = "sessionIdentity.avatarStyle"
    static let defaultValue: SessionAvatarStyle = .initials

    var id: String { rawValue }

    var title: String {
        switch self {
        case .initials:
            String(localized: "Initials")
        case .zora:
            String(localized: "Zora")
        case .orbital:
            String(localized: "Orbital")
        }
    }

    static func storedValue(_ rawValue: String) -> SessionAvatarStyle {
        SessionAvatarStyle(rawValue: rawValue) ?? defaultValue
    }
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
