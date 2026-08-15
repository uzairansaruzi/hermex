import SwiftUI

/// The collapsed one-line stand-in for a turn's thinking and tool blocks.
///
/// Uses the shared 10pt block radius rather than a pill. A capsule read as an
/// oversized lozenge next to the transcript's other cards (`MarkerMessageCardView`
/// and the timeline accessory surface are both 10pt continuous), so the summary
/// now matches the block it stands in for.
///
/// Live turns pass durations and per-tool result dots. Reconstructed history
/// passes neither, because the server persists only name, snippet, tool id,
/// message index, and args — no durations, no error state, no batch grouping.
/// That quieter form is intentional, not a bug.
struct TurnActivitySummaryRow: View {
    let reasoningDuration: TimeInterval?
    let toolCalls: [ToolCall]
    /// Whether the turn had a thinking step at all. A duration implies one, but
    /// history keeps the step while losing the duration.
    var hasReasoning: Bool = true
    var isExpanded: Bool = false
    var onTap: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                Image(systemName: hasFailure ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hasFailure ? Color.red : palette.textSecondary)

                Text(summaryText)
                    .font(AppFont.footnote())
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)

                if !resultDots.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(Array(resultDots.enumerated()), id: \.offset) { _, isError in
                            Circle()
                                .fill(isError ? Color.red : Color.green)
                                .frame(width: 5, height: 5)
                        }
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.textTertiary)
            }
            // Horizontal inset drops with the fill so the header's text lines
            // up with the block titles beneath it instead of sitting 14pt in
            // from nothing.
            .padding(.horizontal, isExpanded ? 2 : 14)
            .padding(.vertical, isExpanded ? 4 : 11)
            // Expanded, the row is a header *for* the blocks below, not a peer
            // of them. Keeping its filled card chrome made it read as a third
            // sibling stacked on two others, which is the "two different cards"
            // complaint in a different form. Dropping to a bare row lets the
            // blocks own the visual weight while the header keeps the position
            // and the control.
            .background(
                ActivityBlockChrome.shape()
                    .fill(palette.surface.opacity(isExpanded ? 0 : 0.8))
            )
            .overlay(
                ActivityBlockChrome.shape()
                    .strokeBorder(palette.tableRule, lineWidth: 1)
                    .opacity(isExpanded ? 0 : 1)
            )
            .contentShape(ActivityBlockChrome.shape())
        }
        .buttonStyle(.plain)
        // The failure triangle and the green/red result dots are visual-only,
        // so the raw summary text hides a failed turn from VoiceOver entirely.
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isExpanded ? "Double tap to collapse activity." : "Double tap to expand activity.")
    }

    private var accessibilityText: String {
        guard hasFailure else { return summaryText }
        let failures = toolCalls.filter { $0.isError == true }.count
        let detail = failures == 1
            ? String(localized: "1 tool failed")
            : String(localized: "\(failures) tools failed")
        return "\(summaryText), \(detail)"
    }

    private var hasFailure: Bool {
        toolCalls.contains { $0.isError == true }
    }

    /// At most eight dots; beyond that the row becomes noise rather than a
    /// glance-able result strip.
    private var resultDots: [Bool] {
        // Expanded, every row shows its own result mark, so the strip is a
        // duplicate summary of what is already visible below.
        guard !isExpanded else { return [] }
        guard toolCalls.contains(where: { $0.isCompleted }) else { return [] }
        return toolCalls.prefix(8).map { $0.isError == true }
    }

    private var summaryText: String {
        // Expanded, the blocks below state their own durations and counts, so
        // repeating "Thought for 12s · ran 6 tools in 13s" in the header is
        // noise. The row keeps its place as the anchor and gets out of the way.
        if isExpanded {
            return String(localized: "Activity")
        }

        var parts: [String] = []

        if let reasoningDuration {
            parts.append(String(localized: "Thought for \(ActivityDurationFormat.string(reasoningDuration))"))
        } else if hasReasoning {
            parts.append(String(localized: "Thought"))
        }

        if !toolCalls.isEmpty {
            let count = toolCalls.count
            let base = count == 1
                ? String(localized: "ran 1 tool")
                : String(localized: "ran \(count) tools")
            let durations = toolCalls.compactMap(\.duration)
            if durations.isEmpty {
                parts.append(base)
            } else {
                parts.append(String(localized: "\(base) in \(ActivityDurationFormat.string(durations.reduce(0, +)))"))
            }
        }

        guard !parts.isEmpty else { return String(localized: "Activity") }
        return parts.joined(separator: " · ")
    }

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(backgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
    }
}
