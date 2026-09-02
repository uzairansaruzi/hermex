import SwiftUI
import UIKit

/// One settled tool call as a dense log line: icon column, bold verb, dim
/// one-line detail, chevron, and a fixed status-glyph slot. Tap expands the
/// same Arguments/Result body the live card shows; long-press copies it.
struct ToolCallLogRowView: View {
    let entry: ToolCallLogEntry

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @State private var isExpanded = false
    @State private var isPressed = false
    @State private var showsCopied = false
    @State private var copiedResetTask: Task<Void, Never>?

    /// Row height at the default text size; text grows the row at larger sizes.
    static let minimumHeight: CGFloat = 32
    /// Icon column width plus the gap, so the expanded body indents under the text.
    private static let bodyIndent: CGFloat = 26

    private var row: ToolCallLogRow { entry.row }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowLine

            if isExpanded {
                expandedBody
                    .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Commands, paths, and results are code-like and stay left-to-right
        // inside an RTL transcript (#259), like the live card.
        .forcedLeftToRight()
        .onDisappear { copiedResetTask?.cancel() }
    }

    private var rowLine: some View {
        HStack(alignment: usesStackedLabel ? .top : .center, spacing: 6) {
            Image(systemName: row.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(row.isFailure ? Color.red : Color.secondary)
                .frame(width: 20, height: 18)

            label
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 1) {
                if showsCopied {
                    Text("Copied")
                        .font(AppFont.caption2(weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.trailing, 4)
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)

                statusGlyph
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 2)
        .frame(minHeight: Self.minimumHeight)
        .background(
            Color.primary.opacity(isPressed ? 0.06 : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleExpansion)
        .onLongPressGesture(minimumDuration: 0.45, perform: copy) { pressing in
            isPressed = pressing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double tap to show details. Long press to copy.")
        .accessibilityAction { toggleExpansion() }
        .accessibilityAction(named: Text("Copy")) { copy() }
    }

    private var usesStackedLabel: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    @ViewBuilder
    private var label: some View {
        if usesStackedLabel {
            VStack(alignment: .leading, spacing: 2) {
                summaryText
                if let detail = row.detail {
                    detailText(detail).lineLimit(2)
                }
            }
        } else if let detail = row.detail {
            (summaryText + Text(" ") + detailText(detail))
                .lineLimit(1)
        } else {
            summaryText.lineLimit(1)
        }
    }

    private var summaryText: Text {
        Text(row.summary)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(row.isFailure ? Color.red : Color.primary)
    }

    private func detailText(_ detail: String) -> Text {
        Text(detail)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
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

    private var expandedBody: some View {
        ToolCallDetailBodyView(toolCall: entry.toolCall)
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)
            }
            .padding(.leading, Self.bodyIndent)
            .padding(.top, 2)
            .padding(.bottom, 6)
    }

    private var accessibilityLabel: String {
        [row.summary, row.detail, row.statusText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func toggleExpansion() {
        chatDisclosureToggled()
        withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
            isExpanded.toggle()
        }
    }

    /// Copies the row and its body, then shows "Copied" for a moment. The reset
    /// task is cancelled when the row leaves the screen so it never mutates a
    /// row that is gone.
    private func copy() {
        isPressed = false
        UIPasteboard.general.string = ToolCallSummaryFormatter.copyText(for: entry.toolCall)
        ChatHaptics.copied(isEnabled: isHapticsEnabled)

        withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
            showsCopied = true
        }

        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                showsCopied = false
            }
        }
    }
}
