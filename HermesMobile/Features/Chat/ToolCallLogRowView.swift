import SwiftUI

/// One tool call as a dense log line: icon column, bold verb, dim one-line
/// detail, chevron, and a status glyph. Tap expands its arguments and result;
/// long-press copies them.
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
            ToolCallDetailBodyView(toolCall: entry.toolCall, status: row.status)
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
        case .running:
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
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

/// The Arguments, Result, and Status sections shown when a tool log row opens.
struct ToolCallDetailBodyView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let toolCall: ToolCall
    let status: ToolCallLogRow.Status

    var body: some View {
        let displayContent = ToolCallDisplayFormatter.content(for: toolCall)

        VStack(alignment: .leading, spacing: 7) {
            if !displayContent.argumentRows.isEmpty {
                argumentsSection(displayContent.argumentRows)
            }

            if let result = displayContent.result {
                resultSection(result)
            }

            if shouldShowStatusDetail(displayContent: displayContent) {
                statusDetail(statusText)
            }
        }
    }

    private var usesStackedRows: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var statusColor: Color {
        status == .failure ? .red : .secondary
    }

    private var statusText: String {
        switch status {
        case .success:
            if let duration = toolCall.duration {
                return "Completed in \(duration.formatted(.number.precision(.fractionLength(1))))s"
            }
            return String(localized: "Completed")
        case .failure:
            return String(localized: "Failed")
        case .running:
            return String(localized: "Running")
        case .interrupted:
            return String(localized: "Interrupted")
        }
    }

    private func shouldShowStatusDetail(displayContent: ToolCallDisplayContent) -> Bool {
        let hasPrimaryContent = !displayContent.argumentRows.isEmpty || displayContent.result != nil
        return !hasPrimaryContent || !toolCall.isCompleted || toolCall.isError == true || toolCall.duration != nil
    }

    private func statusDetail(_ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Status")
                .font(AppFont.caption2(weight: .semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(AppFont.caption())
                .foregroundStyle(statusColor)
                .textSelection(.enabled)
        }
    }

    private func argumentsSection(_ rows: [ToolCallArgumentDisplay]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Arguments")
                .font(AppFont.caption2(weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    argumentRow(row)
                }
            }
            .padding(7)
            .chatTimelineAccessoryInsetSurface()
        }
    }

    private func resultSection(_ result: ToolCallResultDisplay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result.title)
                .font(AppFont.caption2(weight: .semibold))
                .foregroundStyle(.secondary)

            Text(result.text)
                .font(result.isMonospaced ? AppFont.mono(style: .caption) : AppFont.caption())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .chatTimelineAccessoryInsetSurface()
        }
    }

    @ViewBuilder
    private func argumentRow(_ row: ToolCallArgumentDisplay) -> some View {
        if usesStackedRows {
            VStack(alignment: .leading, spacing: 2) {
                argumentKey(row.key)
                argumentValue(row.value)
            }
        } else {
            HStack(alignment: .top, spacing: 7) {
                argumentKey(row.key)
                    .frame(width: 78, alignment: .leading)

                argumentValue(row.value)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func argumentKey(_ value: String) -> some View {
        Text(value)
            .font(AppFont.mono(style: .caption2, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func argumentValue(_ value: String) -> some View {
        Text(value)
            .font(AppFont.mono(style: .caption))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
    }
}
