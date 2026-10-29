import SwiftUI

/// When a tool group's newest row fades in. Only a live group animates, as a
/// new call replaces its newest row; history, reloads, and the rows a
/// reattached stream replays draw in place, and Reduce Motion turns it off.
/// A group that appears whole (its first call) draws in place too, because
/// SwiftUI runs a transition only on the view it inserts, not its children.
enum ToolActivityEntrance {
    static func animatesNewestRow(isLive: Bool, isReplaying: Bool, reduceMotion: Bool) -> Bool {
        isLive && !isReplaying && !reduceMotion
    }
}

/// A turn's tool calls as a dense log. The last call stays visible while earlier
/// calls sit behind a toggle that names what they did ("Changed 2 files and ran
/// 4 commands", with a triangle when one failed), during and after streaming.
struct ToolActivityGroupView: View {
    let group: ToolCallGroup
    var isLive = false
    /// True while a reattached stream replays calls the transcript missed.
    var isReplaying = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @AppStorage(ChatTranscriptDisplaySettings.thinkingAndToolCardsKey) private var thinkingAndToolCards = ThinkingAndToolCards.collapsed
    @State private var userToggledExpansion: Bool?

    /// Whether previous rows are shown. Follows "Expand Tools by Default"
    /// until the user taps the toggle.
    private var isExpanded: Bool {
        ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: thinkingAndToolCards.startsExpanded
        )
    }

    @ViewBuilder
    var body: some View {
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

                // Row identity is the call's stable id, so a start → complete
                // update of the same call keeps the row and never replays this.
                ToolCallLogRowView(entry: lastEntry)
                    .transition(newestRowTransition)
                    .id(lastEntry.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    /// The message rows' one-shot entrance: a 0.22 s fade on insertion only.
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

    /// Collapsed, the title summarizes the hidden rows and a static triangle in
    /// the rows' status column flags a hidden failure; expanded, the rows show
    /// their own marks and the title is "Show fewer tool calls".
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
                    .foregroundStyle(.secondary)
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

    /// The summary wraps at accessibility sizes instead of truncating.
    private var wrapsTitle: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

}
