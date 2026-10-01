import SwiftUI
import UIKit

/// Geometry shared by every log row so the group toggle and the rows line up.
enum TranscriptLogRowMetrics {
    /// Row height at the default text size; text grows the row at larger sizes.
    static let minimumHeight: CGFloat = 32
    /// Icon column width.
    static let iconWidth: CGFloat = 20
    /// Icon column height.
    static let iconHeight: CGFloat = 18
    /// Gap between the icon column and the row's text.
    static let rowSpacing: CGFloat = HermesSpacing.s8
    /// Icon column width plus the gap, so the expanded body indents under the text.
    static let bodyIndent: CGFloat = iconWidth + rowSpacing
    /// Tallest an expanded body gets before it scrolls inside its own window.
    /// Fixed at every Dynamic Type size so a long result never owns the screen.
    static let bodyWindowHeight: CGFloat = 240
}

/// Pure sizing rule for an expanded body window: the frame it takes and
/// whether it scrolls, from the measured content height. Shared by the
/// SwiftUI window and the live thinking text view so both cap alike.
struct TranscriptLogRowBodyWindowLayout: Equatable {
    /// Zero until the content has been measured, then the lesser of its
    /// natural height and the cap. Starting closed prevents one unbounded
    /// layout pass from moving the transcript before the cap takes effect.
    let frameHeight: CGFloat
    let scrolls: Bool

    static func resolve(contentHeight: CGFloat?, cap: CGFloat) -> Self {
        guard let contentHeight else {
            return Self(frameHeight: 0, scrolls: false)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    if contentHeight == nil {
                        // The first bounded measurement opens the body from
                        // zero, so rows below only move down toward their final
                        // positions. Later content changes keep their existing
                        // non-animated sizing behavior.
                        withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                            contentHeight = height
                        }
                    } else {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            contentHeight = height
                        }
                    }
                }
        }
        .scrollDisabled(!layout.scrolls)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: layout.frameHeight)
    }
}

/// The dense log row settled tool calls and thinking share: a 20 pt icon
/// column, bold summary, dim one-line detail, `Copied` badge, an optional
/// trailing accessory, chevron slot, and a fixed status slot so labels align
/// across rows. Tap toggles the owner's expansion state and reveals
/// `expandedBody` under the text behind a hairline, inside a
/// `TranscriptLogRowBodyWindow` that scrolls once the body outgrows the cap;
/// long-press copies `copyText` with a haptic and a short "Copied" badge.
struct TranscriptLogRowView<Icon: View, Accessory: View, Status: View, ExpandedBody: View>: View {
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
    /// Trailing detail before the chevron, such as an edit's "+N −M". It moves to
    /// its own line under the detail when the label stacks at accessibility sizes.
    /// Not read by VoiceOver: fold it into `accessibilityLabel`.
    @ViewBuilder let accessory: () -> Accessory
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
        VStack(alignment: .leading, spacing: HermesSpacing.s0) {
            rowLine

            VStack(alignment: .leading, spacing: HermesSpacing.s0) {
                if isExpanded {
                    TranscriptLogRowBodyWindow(content: expandedBody)
                        .padding(.leading, HermesSpacing.s12)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(.quaternary)
                                .frame(width: 1)
                        }
                        .padding(.leading, TranscriptLogRowMetrics.bodyIndent)
                        .padding(.top, HermesSpacing.s2)
                        .padding(.bottom, HermesSpacing.s8)
                        .transition(
                            .asymmetric(
                                insertion: .opacity,
                                removal: ChatMotion.disclosureTransition(reduceMotion: reduceMotion)
                            )
                        )
                }
            }
            .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { copiedResetTask?.cancel() }
    }

    private var rowLine: some View {
        HStack(alignment: usesStackedLabel ? .top : .center, spacing: HermesSpacing.s8) {
            icon()
                .frame(width: TranscriptLogRowMetrics.iconWidth, height: TranscriptLogRowMetrics.iconHeight)

            label
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: HermesSpacing.s2) {
                if showsCopied {
                    Text("Copied")
                        .appFont(.captionSemibold)
                        .foregroundStyle(.green)
                        .padding(.trailing, HermesSpacing.s4)
                }

                if !usesStackedLabel {
                    accessory()
                        .fixedSize()
                        .padding(.trailing, HermesSpacing.s4)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: HermesIconSize.xs, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: HermesIconSize.small, height: HermesIconSize.small)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: HermesMotion.Duration.d150),
                        value: isExpanded
                    )

                status()
                    .frame(width: HermesIconSize.small, height: HermesIconSize.small)
            }
        }
        .padding(.horizontal, HermesSpacing.s2)
        .frame(minHeight: TranscriptLogRowMetrics.minimumHeight)
        .background(
            Color.primary.opacity(isPressed ? 0.06 : 0),
            in: RoundedRectangle(cornerRadius: HermesRadius.r8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onLongPressGesture(minimumDuration: 0.45, perform: copy) { pressing in
            isPressed = pressing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
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
            VStack(alignment: .leading, spacing: HermesSpacing.s2) {
                summaryText
                if let detail {
                    detailText(detail).lineLimit(2)
                }
                accessory()
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
            .appFont(.captionSemibold, dynamicTypeSize: dynamicTypeSize)
            .foregroundStyle(isFailure ? Color.red : Color.primary)
    }

    private func detailText(_ detail: String) -> Text {
        Text(detail)
            .appFont(.caption, dynamicTypeSize: dynamicTypeSize)
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

extension TranscriptLogRowView where Accessory == EmptyView {
    /// A row with nothing between its label and chevron (thinking, plans).
    init(
        summary: String,
        detail: String?,
        isFailure: Bool = false,
        isExpanded: Bool,
        accessibilityLabel: String,
        copyText: @escaping () -> String,
        toggleExpansion: @escaping () -> Void,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder status: @escaping () -> Status,
        @ViewBuilder expandedBody: @escaping () -> ExpandedBody
    ) {
        self.init(
            summary: summary,
            detail: detail,
            isFailure: isFailure,
            isExpanded: isExpanded,
            accessibilityLabel: accessibilityLabel,
            copyText: copyText,
            toggleExpansion: toggleExpansion,
            icon: icon,
            accessory: { EmptyView() },
            status: status,
            expandedBody: expandedBody
        )
    }
}
