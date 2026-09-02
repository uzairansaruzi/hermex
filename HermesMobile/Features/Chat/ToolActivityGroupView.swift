import SwiftUI

/// A turn's tool calls. While the response streams (`isLive`) the group is the
/// familiar material card of per-call cards, so a running call keeps its
/// status pill. Once the group settles it becomes a dense log: only the last
/// call's row, with the earlier rows behind a `+N previous tool calls` toggle.
struct ToolActivityGroupView: View {
    let group: ToolCallGroup
    var isLive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @AppStorage(ChatTranscriptDisplaySettings.toolCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?

    /// Live: whether the card lists its calls. Settled: whether the previous
    /// rows are shown. Both follow "Expand Tools by Default" until tapped.
    private var isExpanded: Bool {
        ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpanded
        )
    }

    var body: some View {
        if isLive {
            liveCard
        } else {
            settledLog
        }
    }

    private func toggleExpansion() {
        chatDisclosureToggled()
        withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
            userToggledExpansion = !isExpanded
        }
    }

    // MARK: - Settled log

    @ViewBuilder
    private var settledLog: some View {
        let entries = ToolCallSummaryFormatter.entries(for: group.toolCalls)

        if let lastEntry = entries.last {
            let previousEntries = Array(entries.dropLast())

            VStack(alignment: .leading, spacing: 1) {
                if !previousEntries.isEmpty {
                    previousRowsToggle(hiddenCount: previousEntries.count)

                    if isExpanded {
                        ForEach(previousEntries) { entry in
                            ToolCallLogRowView(entry: entry)
                        }
                        .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
                    }
                }

                ToolCallLogRowView(entry: lastEntry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    private func previousRowsToggle(hiddenCount: Int) -> some View {
        Button(action: toggleExpansion) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 18)

                Text(previousRowsToggleTitle(hiddenCount: hiddenCount))
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .frame(minHeight: TranscriptLogRowMetrics.minimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(previousRowsToggleTitle(hiddenCount: hiddenCount))
    }

    private func previousRowsToggleTitle(hiddenCount: Int) -> String {
        isExpanded
            ? String(localized: "Show fewer tool calls")
            : String(localized: "+\(hiddenCount) previous tool calls")
    }

    // MARK: - Live card

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button(action: toggleExpansion) {
                liveHeader
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activityAccessibilityLabel)
            .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.toolCalls) { toolCall in
                        ToolCallCardView(toolCall: toolCall)
                    }
                }
                .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .chatTimelineAccessorySurface(
            fallbackMaterial: .thinMaterial,
            cornerRadius: 10
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var usesStackedHeader: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var liveHeader: some View {
        HStack(alignment: usesStackedHeader ? .top : .center, spacing: 8) {
            Image(systemName: activityIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(activityColor)
                .frame(width: 18, height: 18)

            if usesStackedHeader {
                VStack(alignment: .leading, spacing: 3) {
                    titleText
                    summaryTextView(lineLimit: 2)
                    if let collapsedStateText {
                        TranscriptStatusPill(text: collapsedStateText, color: activityColor)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                    summaryTextView(lineLimit: 1)
                    if let collapsedStateText {
                        TranscriptStatusPill(text: collapsedStateText, color: activityColor)
                    }
                }
            }

            Spacer(minLength: 6)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text(group.activityTitle)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private func summaryTextView(lineLimit: Int) -> some View {
        Text(summaryText)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
    }

    private var activityIcon: String {
        if group.hasFailedTool {
            return "exclamationmark.triangle.fill"
        }

        return group.isComplete ? "checkmark.circle.fill" : "wrench.and.screwdriver.fill"
    }

    private var activityColor: Color {
        if group.hasFailedTool {
            return .red
        }

        return .secondary
    }

    private var collapsedStateText: String? {
        if group.hasFailedTool {
            return String(localized: "Failed")
        }

        return group.isComplete ? nil : String(localized: "Running")
    }

    private var activityAccessibilityLabel: String {
        "\(group.activityTitle), \(activityStateText), \(summaryText)"
    }

    private var activityStateText: String {
        if group.hasFailedTool {
            return String(localized: "Failed")
        }

        return group.isComplete ? String(localized: "Completed") : String(localized: "Running")
    }

    private var summaryText: String {
        let names = group.toolCalls.map(\.displayName)
        let uniqueNames = names.reduce(into: [String]()) { result, name in
            if !result.contains(name) {
                result.append(name)
            }
        }

        guard !uniqueNames.isEmpty else {
            return String(localized: "No tools")
        }

        let visibleNames = uniqueNames.prefix(3)
        let remainingCount = uniqueNames.count - visibleNames.count
        let visibleSummary = visibleNames.joined(separator: ", ")

        guard remainingCount > 0 else {
            return visibleSummary
        }

        return "\(visibleSummary), +\(remainingCount)"
    }
}
