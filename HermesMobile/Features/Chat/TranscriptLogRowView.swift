import SwiftUI
import UIKit

/// Geometry shared by every log row so the group toggle and the rows line up.
enum TranscriptLogRowMetrics {
    /// Row height at the default text size; text grows the row at larger sizes.
    static let minimumHeight: CGFloat = 32
    /// Icon column width plus the gap, so the expanded body indents under the text.
    static let bodyIndent: CGFloat = 26
    /// Tallest an expanded body gets before it scrolls inside its own window.
    /// Fixed at every Dynamic Type size so a long result never owns the screen.
    static let bodyWindowHeight: CGFloat = 240
}

/// Pure sizing rule for an expanded body window: the frame it takes and
/// whether it scrolls, from the measured content height. Shared by the
/// SwiftUI window and the live thinking text view so both cap alike.
struct TranscriptLogRowBodyWindowLayout: Equatable {
    /// `nil` until the content has been measured; the window then sizes to
    /// whatever the content asks for.
    let frameHeight: CGFloat?
    let scrolls: Bool

    static func resolve(contentHeight: CGFloat?, cap: CGFloat) -> Self {
        guard let contentHeight else {
            return Self(frameHeight: nil, scrolls: false)
        }
        return Self(frameHeight: min(contentHeight, cap), scrolls: contentHeight > cap)
    }
}

/// Clips an expanded body at `TranscriptLogRowMetrics.bodyWindowHeight` and
/// scrolls the overflow inside the window. Shorter content takes its natural
/// height and cannot scroll. The measurement lives only here, so collapsed
/// rows in the lazy transcript pay nothing for it.
struct TranscriptLogRowBodyWindow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat?

    var body: some View {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(
            contentHeight: contentHeight,
            cap: TranscriptLogRowMetrics.bodyWindowHeight
        )

        ScrollView(.vertical) {
            content()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    // The window resizes to its content outside the disclosure
                    // animation, so a tall body opens straight at the cap.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        contentHeight = height
                    }
                }
        }
        .scrollDisabled(!layout.scrolls)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: layout.frameHeight)
    }
}

/// The dense log row settled tool calls and thinking share: a 20 pt icon
/// column, bold summary, dim one-line detail, `Copied` badge, chevron slot, and
/// a fixed status slot so labels align across rows. Tap toggles the owner's
/// expansion state and reveals `expandedBody` under the text behind a hairline,
/// inside a `TranscriptLogRowBodyWindow` that scrolls once the body outgrows
/// the cap; long-press copies `copyText` with a haptic and a short "Copied" badge.
struct TranscriptLogRowView<Icon: View, Status: View, ExpandedBody: View>: View {
    let summary: String
    let detail: String?
    var isFailure = false
    let isExpanded: Bool
    let accessibilityLabel: String
    let copyText: () -> String
    /// Flips the owner's expansion state; the row wraps it in the disclosure
    /// animation and suspends the transcript's scroll anchor around it.
    let toggleExpansion: () -> Void
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let status: () -> Status
    @ViewBuilder let expandedBody: () -> ExpandedBody

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @State private var isPressed = false
    @State private var showsCopied = false
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowLine

            if isExpanded {
                TranscriptLogRowBodyWindow(content: expandedBody)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(width: 1)
                    }
                    .padding(.leading, TranscriptLogRowMetrics.bodyIndent)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                    .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { copiedResetTask?.cancel() }
    }

    private var rowLine: some View {
        HStack(alignment: usesStackedLabel ? .top : .center, spacing: 6) {
            icon()
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

                status()
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 2)
        .frame(minHeight: TranscriptLogRowMetrics.minimumHeight)
        .background(
            Color.primary.opacity(isPressed ? 0.06 : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onLongPressGesture(minimumDuration: 0.45, perform: copy) { pressing in
            isPressed = pressing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            isExpanded
                ? "Double tap to hide details. Long press to copy."
                : "Double tap to show details. Long press to copy."
        )
        .accessibilityAction { toggle() }
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
                if let detail {
                    detailText(detail).lineLimit(2)
                }
            }
        } else if let detail {
            (summaryText + Text(" ") + detailText(detail))
                .lineLimit(1)
        } else {
            summaryText.lineLimit(1)
        }
    }

    private var summaryText: Text {
        Text(summary)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(isFailure ? Color.red : Color.primary)
    }

    private func detailText(_ detail: String) -> Text {
        Text(detail)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
    }

    private func toggle() {
        chatDisclosureToggled()
        withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
            toggleExpansion()
        }
    }

    /// Copies the row's text, then shows "Copied" for a moment. The reset task
    /// is cancelled when the row leaves the screen so it never mutates a row
    /// that is gone.
    private func copy() {
        isPressed = false
        UIPasteboard.general.string = copyText()
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
