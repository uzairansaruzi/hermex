import SwiftUI

struct ToolCallCardView: View {
    let toolCall: ToolCall
    /// When rendered inside an already-indented context (e.g. an expanded
    /// `ToolActivityGroupView` list), the parent passes `true` so the quiet
    /// rail doesn't double-indent.
    var isNestedInGroup: Bool = false
    /// Position of this row within its block, used only to stagger the shared
    /// running-indicator sweep so a parallel batch doesn't pulse in lockstep.
    var indicatorRowIndex: Int = 0
    /// Whether the enclosing block is still active. A nested row shows the
    /// travelling indicator only while its block is live; a settled block's
    /// unfinished calls fall back to the static waiting ring.
    var isBlockActive: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue
    @AppStorage(ChatTranscriptDisplaySettings.toolCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?

    private var isExpanded: Bool {
        // Inside a block the row is already one quiet line under the block's
        // own disclosure, so it must not inherit the "start expanded"
        // preference — that setting governs the block, and honouring it here
        // too opens every row at once and repeats the status shown inline.
        if isNestedInGroup {
            return userToggledExpansion ?? false
        }

        return ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpanded
        )
    }

    var body: some View {
        let statusDisplay = ToolCallStatusDisplay(toolCall: toolCall)

        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            if isNestedInGroup {
                // Inside a block the row is a quiet line, not its own capsule:
                // the block owns the single orb and the single border, and the
                // per-row indicator is painted by the block's shared overlay.
                nestedHeader
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(localized: "\(toolCall.displayName), \(statusDisplay.detailText)"))
                    .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")
            } else {
                ActivityCapsuleView(
                    orbState: ThinkingOrbState.forTool(name: toolCall.name),
                    label: capsuleLabel,
                    isActive: isRunning,
                    completedIcon: statusIcon,
                    completedIconColor: toolCall.isError == true ? .red : nil,
                    completedLabel: completedCapsuleLabel,
                    accessory: AnyView(chevron)
                ) {
                    withAnimation(ChatMotion.cardExpand(reduceMotion: reduceMotion)) {
                        userToggledExpansion = !isExpanded
                    }
                }
                .accessibilityLabel(String(localized: "\(toolCall.displayName), \(statusDisplay.detailText)"))
                .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")
            }

            if isExpanded {
                // Quiet indented list: a thin left rail instead of a boxed
                // surface, with the details hanging off it in mono type.
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(palette.tableRule)
                        .frame(width: 2)

                    expandedContent(statusDisplay: statusDisplay)
                }
                .padding(.leading, isNestedInGroup ? 4 : 8)
                // Tool-call bodies are commands, JSON, file paths, and
                // results — code-like content that must stay left-to-right
                // inside an RTL message (#259).
                .forcedLeftToRight()
                .transition(ChatMotion.cardContentTransition(reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(backgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
    }

    private var chevron: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// One line inside a tool block: indicator slot, name, subject, and the
    /// duration or failure note. No capsule chrome, no orb, no beam.
    private var nestedHeader: some View {
        Button {
            withAnimation(ChatMotion.cardExpand(reduceMotion: reduceMotion)) {
                userToggledExpansion = !isExpanded
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ToolRunIndicatorSlot(
                    toolCall: toolCall,
                    rowIndex: indicatorRowIndex,
                    isBlockActive: isBlockActive
                )
                .alignmentGuide(.firstTextBaseline) { dimension in
                    // Keep the glyph optically on the text baseline; without
                    // this the slot's own height drives the alignment and the
                    // row jitters when a label wraps.
                    dimension[VerticalAlignment.center] + 4
                }

                Text(toolCall.displayName)
                    .font(AppFont.footnote())
                    .foregroundStyle(palette.textPrimary)

                if let subject = nestedSubject {
                    Text(subject)
                        .font(AppFont.footnote())
                        .foregroundStyle(palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 6)

                if let trailing = nestedTrailingText {
                    Text(trailing)
                        .font(AppFont.caption2())
                        .foregroundStyle(toolCall.isError == true ? .red : palette.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The path-like argument shown after the tool name, if any.
    private var nestedSubject: String? {
        let rows = ToolCallDisplayFormatter.argumentRows(from: toolCall.args)
        let pathKeys = ["path", "file_path", "filepath", "file", "cmd", "command", "query", "url"]
        guard let subject = pathKeys
            .compactMap({ key in rows.first { $0.key.lowercased() == key }?.value })
            .first,
            !subject.isEmpty
        else {
            return nil
        }

        return subject.contains("/") && !subject.contains(" ")
            ? String(subject.split(separator: "/").last ?? Substring(subject))
            : subject
    }

    private var nestedTrailingText: String? {
        if toolCall.isError == true {
            return String(localized: "Failed")
        }
        guard toolCall.isCompleted, let duration = toolCall.duration else { return nil }
        return ActivityDurationFormat.string(duration)
    }

    /// Short activity title in "Reading ChatPalette.swift" style: the tool's
    /// display name plus the most path-like argument, middle-truncated by the
    /// capsule's label line.
    private var capsuleLabel: String {
        let rows = ToolCallDisplayFormatter.argumentRows(from: toolCall.args)
        let pathKeys = ["path", "file_path", "filepath", "file", "cmd", "command", "query", "url"]
        let subject = pathKeys
            .compactMap { key in rows.first { $0.key.lowercased() == key }?.value }
            .first

        guard let subject, !subject.isEmpty else {
            return toolCall.displayName
        }

        // Prefer the last path component for file-ish values.
        let trimmed = subject.contains("/") && !subject.contains(" ")
            ? String(subject.split(separator: "/").last ?? Substring(subject))
            : subject
        return "\(toolCall.displayName) \(trimmed)"
    }

    /// Completed label keeps the activity title and appends the tool's
    /// duration when the backend reported one: "Read ChatPalette.swift · 3.4s".
    private var completedCapsuleLabel: String {
        guard let duration = toolCall.duration, toolCall.isError != true else {
            return capsuleLabel
        }
        return "\(capsuleLabel) · \(ActivityDurationFormat.string(duration))"
    }

    private func expandedContent(statusDisplay: ToolCallStatusDisplay) -> some View {
        let displayContent = ToolCallDisplayFormatter.content(for: toolCall)

        return VStack(alignment: .leading, spacing: 8) {
            if !displayContent.argumentRows.isEmpty {
                argumentsSection(displayContent.argumentRows)
            }

            if let result = displayContent.result {
                resultSection(result)
            }

            if shouldShowStatusDetail(displayContent: displayContent) {
                statusDetail(statusDisplay.detailText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var usesStackedHeader: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var statusIcon: String {
        if toolCall.isError == true {
            return "exclamationmark.triangle.fill"
        }

        return toolCall.isCompleted ? "checkmark.circle.fill" : "wrench.and.screwdriver.fill"
    }

    private var isRunning: Bool {
        toolCall.isError != true && !toolCall.isCompleted
    }

    private var statusColor: Color {
        if toolCall.isError == true {
            return .red
        }

        return .secondary
    }

    private func shouldShowStatusDetail(displayContent: ToolCallDisplayContent) -> Bool {
        let hasPrimaryContent = !displayContent.argumentRows.isEmpty || displayContent.result != nil
        return !hasPrimaryContent || !toolCall.isCompleted || toolCall.isError == true || toolCall.duration != nil
    }

    private func statusDetail(_ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: statusIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(toolCall.isError == true ? .red : palette.textTertiary)

            Text(value)
                .font(AppFont.caption())
                .foregroundStyle(toolCall.isError == true ? statusColor : palette.textTertiary)
                .textSelection(.enabled)
        }
    }

    private func argumentsSection(_ rows: [ToolCallArgumentDisplay]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                argumentRow(row)
            }
        }
    }

    private func resultSection(_ result: ToolCallResultDisplay) -> some View {
        Text(result.text)
            .font(result.isMonospaced ? AppFont.mono(style: .caption) : AppFont.caption())
            .foregroundStyle(palette.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func argumentRow(_ row: ToolCallArgumentDisplay) -> some View {
        if usesStackedHeader {
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
            .foregroundStyle(palette.textTertiary)
            .lineLimit(1)
    }

    private func argumentValue(_ value: String) -> some View {
        Text(value)
            .font(AppFont.mono(style: .caption))
            .foregroundStyle(palette.textSecondary)
            .textSelection(.enabled)
    }
}

struct ToolCallStatusDisplay: Equatable {
    let collapsedText: String?
    let detailText: String

    init(toolCall: ToolCall) {
        if toolCall.isError == true {
            collapsedText = String(localized: "Failed")
            detailText = String(localized: "Failed")
            return
        }

        if toolCall.isCompleted {
            collapsedText = nil
            if let duration = toolCall.duration {
                detailText = "Completed in \(duration.formatted(.number.precision(.fractionLength(1))))s"
            } else {
                detailText = String(localized: "Completed")
            }
            return
        }

        collapsedText = String(localized: "Running")
        detailText = String(localized: "Running")
    }
}

struct TranscriptStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(AppFont.caption2(weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}
