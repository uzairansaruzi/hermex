import SwiftUI

/// One settled tool call as a dense log line: icon column, bold verb, dim
/// one-line detail, chevron, and a status glyph. Tap expands the same
/// Arguments/Result body the live card shows; long-press copies it.
struct ToolCallLogRowView: View {
    let entry: ToolCallLogEntry

    @State private var isExpanded = false

    private var row: ToolCallLogRow { entry.row }

    var body: some View {
        TranscriptLogRowView(
            summary: row.summary,
            detail: row.detail,
            isFailure: row.isFailure,
            isExpanded: isExpanded,
            accessibilityLabel: accessibilityLabel,
            copyText: { ToolCallSummaryFormatter.copyText(for: entry.toolCall) },
            toggleExpansion: { isExpanded.toggle() }
        ) {
            Image(systemName: row.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(row.isFailure ? Color.red : Color.secondary)
        } status: {
            statusGlyph
        } expandedBody: {
            ToolCallDetailBodyView(toolCall: entry.toolCall)
        }
        // Commands, paths, and results are code-like and stay left-to-right
        // inside an RTL transcript (#259), like the live card.
        .forcedLeftToRight()
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch row.status {
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        case .failure:
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
        case .interrupted:
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityLabel: String {
        [row.summary, row.detail, row.statusText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
