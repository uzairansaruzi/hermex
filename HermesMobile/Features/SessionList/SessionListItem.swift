import SwiftUI

/// A new, foundation-only Sessions composition under the List/ListItem family, with no production
/// call site: streaming indication, search highlighting, session metadata and Tags, attention
/// status, Dynamic Type reflow, and the accessibility summary. Production's live session row is
/// `SessionRowView`, which `SessionInteractiveRow` (`SessionListComponents.swift`) wraps with the
/// native Button, selection background, swipe actions, context menus, and transitions this
/// composition would need if it were ever adopted.
struct SessionListItem: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var pinnedIconSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var verticalPadding: CGFloat = 8

    let session: SessionSummary
    var showsMessageCount = true
    var showsWorkspace = true
    var isViewingCachedData = false
    var isUnread = false
    /// The resolved attention state for this row, supplied by the screen that
    /// polls the server (`SessionListViewModel`). Screens that do not poll pass
    /// nothing and the row falls back to what the session itself reports.
    var attentionState: SessionListItemAttentionState?
    /// Set only while a remote content search is showing this row, so the row
    /// can say why it matched.
    var searchExcerpt: SessionSearchExcerpt?

    var body: some View {
        HStack(alignment: .top, spacing: HermesSpacing.s12) {
            if Self.isActiveStreaming(session) && !isViewingCachedData {
                ActiveSessionStreamingIndicator()
                    .padding(.top, streamingIndicatorTopPadding)
            } else if isUnread && effectiveAttentionState == nil {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .padding(.top, streamingIndicatorTopPadding)
                    .accessibilityHidden(true)
            }

            rowContent
        }
        .padding(.vertical, verticalPadding)
        .frame(minHeight: rowMinimumHeight, alignment: .center)
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

    /// The state the row actually shows: what the polling screen resolved, or —
    /// for screens that do not poll — whatever the session alone can say.
    ///
    /// The fallback is off while the row is showing cached data: a cached
    /// summary keeps whatever `isStreaming`/`activeStreamId` it was captured
    /// with, so an offline row would otherwise claim the agent is still
    /// working. Cached rows fall back to their relative time instead.
    static func effectiveAttentionState(
        for session: SessionSummary,
        attentionState: SessionListItemAttentionState?,
        isViewingCachedData: Bool
    ) -> SessionListItemAttentionState? {
        if let attentionState {
            return attentionState
        }

        guard !isViewingCachedData else { return nil }

        return SessionListItemAttentionState.resolve(
            session: session,
            hasPendingApproval: false,
            hasPendingClarification: false
        )
    }

    static func accessibilityStateLabels(
        for session: SessionSummary,
        isViewingCachedData: Bool,
        attentionState: SessionListItemAttentionState? = nil,
        isUnread: Bool = false
    ) -> [String] {
        var labels: [String] = []

        if let state = effectiveAttentionState(
            for: session,
            attentionState: attentionState,
            isViewingCachedData: isViewingCachedData
        ) {
            labels.append(state.accessibilityLabel)
        } else if isUnread {
            labels.append(String(localized: "Unread"))
        }

        if session.pinned == true {
            labels.append(String(localized: "Pinned"))
        }

        if isViewingCachedData {
            labels.append(String(localized: "Cached"))
        }

        if let sourceLabel = session.sourceDisplayLabel {
            labels.append(sourceLabel)
        }

        if session.isSessionReadOnly {
            labels.append(String(localized: "Read-only"))
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
            VStack(alignment: .leading, spacing: HermesSpacing.s4) {
                titleAndPin

                trailingStatusSlot
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: HermesSpacing.s8) {
                titleAndPin

                if showsTrailingStatus {
                    Spacer(minLength: 8)
                }

                trailingStatusSlot
            }
        }
    }

    /// One line, one meaning: the attention state when the session wants
    /// something, otherwise the relative time. Never both, so the row keeps its
    /// height in every state.
    @ViewBuilder
    private var trailingStatusSlot: some View {
        if let effectiveAttentionState {
            attentionStateText(effectiveAttentionState)
        } else if let relativeDate {
            relativeDateText(relativeDate)
        }
    }

    private var showsTrailingStatus: Bool {
        effectiveAttentionState != nil || relativeDate != nil
    }

    private var effectiveAttentionState: SessionListItemAttentionState? {
        Self.effectiveAttentionState(
            for: session,
            attentionState: attentionState,
            isViewingCachedData: isViewingCachedData
        )
    }

    private func attentionStateText(_ state: SessionListItemAttentionState) -> some View {
        Text(state.title)
            .appFont(.captionSemibold)
            .foregroundStyle(state.tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    private var titleAndPin: some View {
        HStack(alignment: .firstTextBaseline, spacing: HermesSpacing.s8) {
            Text(displayTitle)
                .appFont(.label)
                .foregroundStyle(.primary)
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
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    /// One-line "why this row matched", with the query bolded. Hidden from
    /// VoiceOver because `accessibilitySummary` already reads it in order.
    private func excerptText(_ excerpt: SessionSearchExcerpt) -> some View {
        Text(excerpt.highlighted)
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(excerptLineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var supplementalArea: some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: HermesSpacing.s8) {
                VStack(alignment: .leading, spacing: HermesSpacing.s4) {
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
            HStack(alignment: .firstTextBaseline, spacing: HermesSpacing.s8) {
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
        HStack(spacing: HermesSpacing.s4) {
            ForEach(visibleStateBadges) { badge in
                SessionRowStateBadge(badge: badge)
            }
        }
    }

    private func metadataText(_ text: String) -> some View {
        Text(text)
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(metadataLineLimit)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var visibleStateBadges: [SessionRowStateBadgeKind] {
        // Streaming has no badge: the trailing "Working" label and the pulsing
        // dot already say it, and a third marker only added noise.
        var badges: [SessionRowStateBadgeKind] = []

        if isViewingCachedData {
            badges.append(.cached)
        }

        if session.isSessionReadOnly {
            badges.append(.readOnly)
        }

        return badges
    }

    private var showsStateBadges: Bool {
        session.sourceDisplayLabel != nil || !visibleStateBadges.isEmpty
    }

    private var showsSupplementalContent: Bool {
        metadataLabel != nil || showsStateBadges
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

    private var streamingIndicatorTopPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 8 : 7
    }

    private var relativeDate: String? {
        let timestamp = session.lastMessageAt ?? session.updatedAt ?? session.createdAt
        guard let timestamp, timestamp > 0 else { return nil }

        return SessionListItemRelativeDateFormatter.shared.localizedString(
            for: Date(timeIntervalSince1970: timestamp),
            relativeTo: Date()
        )
    }

    private var accessibilitySummary: String {
        var parts = [displayTitle]

        if let searchExcerpt {
            parts.append(String(localized: "Matched: \(searchExcerpt.text)"))
        }

        parts.append(contentsOf: Self.accessibilityStateLabels(
            for: session,
            isViewingCachedData: isViewingCachedData,
            attentionState: attentionState,
            isUnread: isUnread
        ))

        if let metadataLabel {
            parts.append(metadataLabel)
        }

        if let relativeDate {
            parts.append(relativeDate)
        }

        return parts.joined(separator: ", ")
    }
}

/// What one session row is asking of the user, shown where the relative time
/// otherwise sits. `nil` means no attention is pending: the row shows its
/// time, with an unread dot when a newer settled reply exists.
enum SessionListItemAttentionState: String, Equatable {
    case approval
    case input
    case working

    /// Precedence: approval → input → working → ready. Pure by design — the
    /// caller decides which sessions are worth asking the server about, so a
    /// pending flag on a non-streaming session still resolves here.
    static func resolve(
        session: SessionSummary,
        hasPendingApproval: Bool,
        hasPendingClarification: Bool
    ) -> SessionListItemAttentionState? {
        if hasPendingApproval {
            return .approval
        }

        if hasPendingClarification {
            return .input
        }

        return SessionListItem.isActiveStreaming(session) ? .working : nil
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cached:
            return String(localized: "Cached")
        case .readOnly:
            return String(localized: "Read-only")
        }
    }

    var tint: Color {
        switch self {
        case .cached:
            return .orange
        case .readOnly:
            return .gray
        }
    }
}

private struct SessionSourceBadge: View {
    let label: String

    var body: some View {
        Tag(label: label, tint: .accentColor, size: .compact, isDecorative: true)
    }
}

private struct SessionRowStateBadge: View {
    let badge: SessionRowStateBadgeKind

    var body: some View {
        Tag(label: badge.title, tint: badge.tint, size: .compact, isDecorative: true)
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
            .onAppear {
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
        guard !reduceMotion else {
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

/// Shared "2h ago" formatter for session and Bot rows.
enum SessionListItemRelativeDateFormatter {
    static let shared: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
