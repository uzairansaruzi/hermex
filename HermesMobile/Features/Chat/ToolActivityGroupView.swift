import SwiftUI

enum ToolActivityEntrance {
    static func animatesNewestRow(isLive: Bool, isReplaying: Bool, reduceMotion: Bool) -> Bool {
        isLive && !isReplaying && !reduceMotion
    }
}

struct ToolActivityGroupView: View {
    let group: ToolCallGroup
    var isLive = false
    var isReplaying = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @AppStorage(ChatTranscriptDisplaySettings.thinkingAndToolCardsKey) private var thinkingAndToolCards = ThinkingAndToolCards.collapsed
    @State private var userToggledExpansion: Bool?

    private var isExpanded: Bool {
        ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: thinkingAndToolCards.startsExpanded
        )
    }

    @ViewBuilder
    var body: some View {
        let _ = RenderProbe.hit(.toolActivityGroup)
        let entries = ToolCallSummaryFormatter.entries(for: group.toolCalls, isLive: isLive)

        if let lastEntry = entries.last {
            let previousEntries = Array(entries.dropLast())

            VStack(alignment: .leading, spacing: 1) {
                if !previousEntries.isEmpty {
                    previousRowsToggle(hiddenEntries: previousEntries)

                    if isExpanded {
                        ForEach(previousEntries) { entry in
                            ToolCallLogRowView(entry: entry)
                        }
                        .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
                    }
                }

                ToolCallLogRowView(entry: lastEntry)
                    .transition(newestRowTransition)
                    .id(lastEntry.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    private var newestRowTransition: AnyTransition {
        guard ToolActivityEntrance.animatesNewestRow(
            isLive: isLive,
            isReplaying: isReplaying,
            reduceMotion: reduceMotion
        ) else {
            return .identity
        }
        return ChatMotion.freshRowTransition(isUserRow: false, reduceMotion: reduceMotion)
    }

    private func toggleExpansion() {
        chatDisclosureToggled()
        withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
            userToggledExpansion = !isExpanded
        }
    }

    private func previousRowsToggle(hiddenEntries: [ToolCallLogEntry]) -> some View {
        let summary = isExpanded ? nil : ToolCallGroupSummary(entries: hiddenEntries)
        let title = if isExpanded {
            String(localized: "Show fewer tool calls")
        } else {
            summary?.sentence ?? String(localized: "+\(hiddenEntries.count) previous tool calls")
        }

        return Button(action: toggleExpansion) {
            HStack(alignment: wrapsTitle ? .top : .center, spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.appSecondary)
                    .frame(width: 20, height: 18)

                Text(title)
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(wrapsTitle ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let summary, summary.failedCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 2)
            .frame(minHeight: TranscriptLogRowMetrics.minimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary?.accessibilityLabel(title: title) ?? title)
    }

    private var wrapsTitle: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

}
