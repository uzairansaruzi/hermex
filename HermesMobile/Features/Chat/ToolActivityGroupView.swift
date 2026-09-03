import SwiftUI

/// A turn's tool calls as a dense log. The last call stays visible while earlier
/// calls sit behind a `+N previous tool calls` toggle, during and after streaming.
struct ToolActivityGroupView: View {
    let group: ToolCallGroup
    var isLive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @AppStorage(ChatTranscriptDisplaySettings.toolCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?

    /// Whether previous rows are shown. Follows "Expand Tools by Default"
    /// until the user taps the toggle.
    private var isExpanded: Bool {
        ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpanded
        )
    }

    @ViewBuilder
    var body: some View {
        let entries = ToolCallSummaryFormatter.entries(for: group.toolCalls, isLive: isLive)

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
                    .id(lastEntry.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    private func toggleExpansion() {
        chatDisclosureToggled()
        withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
            userToggledExpansion = !isExpanded
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

}
